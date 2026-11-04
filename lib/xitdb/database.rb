# frozen_string_literal: true

module XitDB
  class Database
    attr_reader :core, :profile

    def self.hasher(value)
      if value.is_a?(Core::Hasher)
        raise ProfileMismatchError, "rb01 is reserved for XitDB::Ruby" if value.id == "rb01"

        return value
      end
      unless %i[sha1 sha256 sha384 sha512].include?(value)
        raise ArgumentError, "hash must be a builtin algorithm or Core::Hasher"
      end

      Core::Hasher.public_send(value)
    end

    def self.open(path, readonly: false, hash: nil, lock_timeout: 5.0)
      selected = hasher(hash) unless hash.nil?
      options = selected ? {hash_id: selected.id, hash_size: selected.size} : {}
      store, created = open_store(path, readonly: readonly)
      begin
        core = Core::Database.new(store: store, initialize_empty: created, lock_timeout: lock_timeout, **options)
        if core.header.hash_id == "rb01"
          raise ProfileMismatchError, "Ruby profile file requires XitDB::Ruby.open"
        end
        selected ||= case [core.header.hash_id, core.header.hash_size]
        when ["sha1", 20] then Core::Hasher.sha1
        when ["sha2", 32] then Core::Hasher.sha256
        when ["sha2", 48] then Core::Hasher.sha384
        when ["sha2", 64] then Core::Hasher.sha512
        else raise ProfileMismatchError, "unknown hash identifier or size; supply an explicit hash configuration"
        end
        database = new(core: core, profile: Profiles::Portable.new(hasher: selected), readonly: readonly)
      rescue Exception
        store.close rescue nil
        raise
      end
      return database unless block_given?

      begin
        yield database
      ensure
        database.close
      end
    end

    def self.open_store(path, readonly:)
      return [Core::FileStore.open(path, readonly: true), false] if readonly

      begin
        [Core::FileStore.open(path, exclusive: true), true]
      rescue Errno::EEXIST
        [Core::FileStore.open(path, create: false), false]
      end
    end
    private_class_method :open_store

    def self.memory(hash: :sha1)
      selected = hasher(hash)
      database = new(core: Core::Database.memory(hash_id: selected.id, hash_size: selected.size),
                     profile: Profiles::Portable.new(hasher: selected))
      return database unless block_given?

      begin
        yield database
      ensure
        database.close
      end
    end

    def initialize(core:, profile:, readonly: false)
      @core = core
      @profile = profile
      @readonly = readonly
      snapshot
    end

    def transaction
      raise ArgumentError, "transaction requires a block" unless block_given?
      raise ReadOnlyError, "database is read-only" if @readonly

      core.with_operation { perform_transaction { |root| yield root } }
    end

    def perform_transaction
      committed = core.transaction do |history_cursor|
        array = history_array(history_cursor)
        slot = array.size.zero? ? Core::Slot.new : array.get(-1)
        context = Context.new(database: self, root: slot, bound: history_cursor.bound,
                              transaction: history_cursor.transaction)
        validate_root(slot, context) unless array.size.zero?
        root = context.view(slot, path: [], kind: :map)
        yield root
        if context.changed?
          array.append(context.root)
        else
          history_cursor.transaction.cancel_publication
        end
      end
      snapshot_from_cursor(committed)
    end
    private :perform_transaction

    def snapshot(revision: nil)
      core.with_operation do
        if revision
          raise TypeError, "revision must be an XitDB::Revision" unless revision.is_a?(Revision)

          return revision.resolve(self)
        end
        snapshot_from_cursor(core.root_cursor)
      end
    end

    def history
      core.check_open!
      History.new(self)
    end

    def revert(value)
      core.with_operation { perform_revert(value) }
    end

    def perform_revert(value)
      target = if value.is_a?(Snapshot)
        unless value.context.database.core.header.file_id == core.header.file_id
          raise ForeignRevisionError, "snapshot belongs to another database"
        end
        value.revision ? snapshot(revision: value.revision) : value
      elsif value.is_a?(Revision)
        snapshot(revision: value)
      else
        raise TypeError, "revert requires a Snapshot or Revision"
      end
      raise ReadOnlyError, "database is read-only" if @readonly

      committed = core.transaction do |cursor|
        # Validate again under the writer lock in case the file was restored.
        selected = target.revision ? snapshot(revision: target.revision) : target
        slot = selected.slot
        if slot.empty?
          context = Context.new(database: self, root: slot, bound: cursor.bound, transaction: cursor.transaction)
          slot = profile.encode({}, context: context, path: [])
        end
        history_array(cursor).append(slot)
      end
      snapshot_from_cursor(committed)
    end
    private :perform_revert

    def close
      core.close
    end

    def compact(to:)
      compacted = core.compact(to: to)
      begin
        copied_profile = if core.header.hash_id == "rb01"
          Profiles::Ruby.new(codecs: profile.codecs)
        else
          Profiles::Portable.new(hasher: profile.hasher)
        end
        self.class.new(core: compacted, profile: copied_profile)
      rescue Exception
        compacted.close
        raise
      end
    end

    def closed?
      core.closed?
    end

    # Conventional history is shared by profiles; logical roots use the profile seam.
    def history_array(cursor)
      unless cursor.slot.empty? || cursor.slot.tag == :array_list
        raise ProfileMismatchError, "public databases require a top-level history array"
      end
      Core::ArrayList.new(cursor)
    end

    def snapshot_from_history(cursor, index, revision: nil)
      core.with_operation do
        slot = history_array(cursor).get(index)
        raise IndexError, "history index outside history" unless slot
        raise ProfileMismatchError, "history entry must contain a root map" if slot.empty?

        context = Context.new(database: self, root: slot, bound: cursor.bound)
        validate_root(slot, context)
        revision ||= revision_for(cursor, index)
        Snapshot.new(context: context, revision: revision)
      end
    end

    private

    def validate_root(slot, context)
      adapter = profile.container(slot, context: context, path: []) unless slot.empty?
      unless adapter && %i[map sorted_map].include?(adapter.kind)
        raise ProfileMismatchError, "history entry must contain a root map"
      end
    end

    def snapshot_from_cursor(cursor)
      count = history_array(cursor).size
      return snapshot_from_history(cursor, count - 1) unless count.zero?

      Snapshot.new(context: Context.new(database: self, root: Core::Slot.new, bound: cursor.bound), revision: nil)
    end

    def revision_for(cursor, index)
      position = cursor.bound - Core::Database::TRAILER_SIZE
      checksum = core.read_at(position + 17, 8, bound: cursor.bound).unpack1("Q>")
      Revision.new(file_id: core.header.file_id, trailer_position: position, checksum: checksum, index: index)
    end
  end

  def self.open(path, readonly: false, hash: nil, lock_timeout: 5.0, &block)
    Database.open(path, readonly: readonly, hash: hash, lock_timeout: lock_timeout, &block)
  end

  def self.memory(hash: :sha1, &block)
    Database.memory(hash: hash, &block)
  end
end
