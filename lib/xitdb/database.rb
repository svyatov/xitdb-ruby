# frozen_string_literal: true

require_relative "conversion"

# Persistent collections with immutable snapshots and explicit transactions.
module XitDB
  # Owns the profile, history, and transactions of a public database.
  class Database
    attr_reader :core, :profile

    def self.hasher(value)
      if value.is_a?(Core::Hasher)
        raise ProfileMismatchError, "rb01 is reserved for XitDB::Ruby" if value.id == "rb01"

        return value
      end
      case value
      when :sha1 then Core::Hasher.sha1
      when :sha256 then Core::Hasher.sha256
      when :sha384 then Core::Hasher.sha384
      when :sha512 then Core::Hasher.sha512
      else
        raise ArgumentError, "hash must be a builtin algorithm or Core::Hasher"
      end
    end

    def self.open(path, readonly: false, hash: nil, lock_timeout: 5.0)
      selected = hasher(hash) unless hash.nil?
      # @type var options: { ?hash_id: String, ?hash_size: Integer }
      options = selected ? { hash_id: selected.id, hash_size: selected.size } : {}
      store, created = open_store(path, readonly: readonly)
      begin
        core = Core::Database.new(store: store, initialize_empty: created, lock_timeout: lock_timeout, **options)
        raise ProfileMismatchError, "Ruby profile file requires XitDB::Ruby.open" if core.header.hash_id == "rb01"

        selected ||= header_hasher(core.header)
        database = new(core: core, profile: Profiles::Portable.new(hasher: selected), readonly: readonly)
      rescue Exception # rubocop:disable Lint/RescueException -- Close owned storage on Interrupt and SystemExit.
        store.send(:close_unreturned)
        raise
      end
      return database unless block_given?

      begin
        yield database
      ensure
        database.close
      end
    end

    def self.header_hasher(header)
      case [header.hash_id, header.hash_size]
      when ["sha1", 20] then Core::Hasher.sha1
      when ["sha2", 32] then Core::Hasher.sha256
      when ["sha2", 48] then Core::Hasher.sha384
      when ["sha2", 64] then Core::Hasher.sha512
      else raise ProfileMismatchError, "unknown hash identifier or size; supply an explicit hash configuration"
      end
    end
    private_class_method :header_hasher

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

    def transaction(&block)
      raise ArgumentError, "transaction requires a block" unless block_given?
      raise ReadOnlyError, "database is read-only" if @readonly

      core.with_operation { perform_transaction(&block) }
    end

    def perform_transaction
      committed = core.transaction do |history_cursor|
        array = history_array(history_cursor)
        empty = array.size.zero? # rubocop:disable Style/ZeroLengthPredicate -- Core arrays expose size, not empty?.
        slot = empty ? Core::Slot.new : (array.get(-1) || raise(CorruptionError, "missing history root"))
        context = Context.new(database: self, root: slot, bound: history_cursor.bound,
                              transaction: history_cursor.transaction)
        validate_root(slot, context) unless empty
        root = context.view(slot, path: [], kind: :map)
        yield root
        if context.changed?
          array.append(context.root)
        else
          context.writable_transaction.cancel_publication
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
        selected_profile = profile
        copied_profile = if defined?(Profiles::Ruby) && selected_profile.is_a?(Profiles::Ruby)
                           Profiles::Ruby.new(codecs: selected_profile.codecs)
                         else
                           Profiles::Portable.new(hasher: profile.hasher)
                         end
        self.class.new(core: compacted, profile: copied_profile)
      rescue Exception # rubocop:disable Lint/RescueException -- Close owned storage on Interrupt and SystemExit.
        compacted.send(:close_unreturned)
        raise
      end
    end

    def closed?
      core.closed?
    end

    def convert(to:, profile:, history: :all, transform: nil)
      raise ArgumentError, "history must be :all or :latest" unless %i[all latest].include?(history)
      raise TypeError, "transform must respond to call" unless transform.nil? || transform.respond_to?(:call)

      require_relative "ruby"
      target_profile = conversion_profile(profile)
      core.with_operation do
        captured = core.root_cursor
        histories = history_array(captured)
        store = Core::FileStore.open(to)
        completed = published = false
        # @type var target_core: Core::Database?
        target_core = nil
        begin
          raise ArgumentError, "conversion target is the source file" if store.storage_identity == core.storage_identity

          created_core = Core::Database.new(store: store, hash_id: target_profile.hasher.id,
                                            hash_size: target_profile.hasher.size, require_empty: true)
          target_core = created_core
          target = Database.new(core: created_core, profile: target_profile)
          copy_history(target, store, captured, histories, history, transform)
          published = true
          completed = true
          target
        ensure
          unless completed
            target_core&.send(:restore_empty_target) unless published
            store.send(:close_unreturned)
          end
        end
      end
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

    def conversion_profile(selected)
      source_profile = profile
      case selected
      when :portable
        Profiles::Portable.new(hasher: source_profile.instance_of?(Profiles::Portable) ? source_profile.hasher : Core::Hasher.sha1)
      when :ruby
        Profiles::Ruby.new(codecs: source_profile.is_a?(Profiles::Ruby) ? source_profile.codecs : [])
      else
        if selected.instance_of?(Profiles::Portable)
          Profiles::Portable.new(hasher: selected.hasher)
        elsif selected.instance_of?(Profiles::Ruby)
          Profiles::Ruby.new(codecs: selected.codecs)
        else
          raise ArgumentError, "profile must be :portable, :ruby, or a supported profile instance"
        end
      end
    end

    def copy_history(target, store, captured, histories, history, transform)
      target_core = target.core
      target_core.transaction do |cursor|
        current_header = Core::Header.parse(store.read_at(0, Core::Header::SIZE))
        unchanged = current_header.file_id == target_core.header.file_id && cursor.bound == Core::Database::MINIMUM_SIZE
        raise ArgumentError, "conversion target changed before copying" unless unchanged && cursor.slot.empty?

        if histories.size.zero? # rubocop:disable Style/ZeroLengthPredicate -- Core arrays expose size, not empty?.
          transaction = cursor.transaction || raise(ReadOnlyError, "conversion requires a transaction")
          transaction.cancel_publication
          next
        end
        output = Core::ArrayList.new(cursor)
        first = history == :latest ? histories.size - 1 : 0
        (first...histories.size).each do |index|
          source = snapshot_from_history(captured, index).context
          destination = Context.new(database: target, root: Core::Slot.new,
                                    bound: cursor.bound, transaction: cursor.transaction)
          transaction = destination.writable_transaction
          transaction.with_logical_mutation do
            output.append(Conversion.new(source, destination, transform: transform).copy(source.root))
            transaction.freeze
          end
        end
      end
    end

    def validate_root(slot, context)
      adapter = profile.container(slot, context: context, path: []) unless slot.empty?
      return if adapter && %i[map sorted_map].include?(adapter.kind)

      raise ProfileMismatchError, "history entry must contain a root map"
    end

    def snapshot_from_cursor(cursor)
      count = history_array(cursor).size
      return snapshot_from_history(cursor, count - 1) unless count.zero?

      Snapshot.new(context: Context.new(database: self, root: Core::Slot.new, bound: cursor.bound), revision: nil)
    end

    def revision_for(cursor, index)
      position = cursor.bound - Core::Database::TRAILER_SIZE
      checksum = core.read_at(position + 17, 8, bound: cursor.bound).unpack1("Q>")
      raise CorruptionError, "invalid history checksum" unless checksum.is_a?(Integer)

      Revision.new(file_id: core.header.file_id, trailer_position: position, checksum: checksum, index: index)
    end
  end

  def self.open(path, readonly: false, hash: nil, lock_timeout: 5.0, &block)
    if block
      Database.open(path, readonly: readonly, hash: hash, lock_timeout: lock_timeout, &block)
    else
      Database.open(path, readonly: readonly, hash: hash, lock_timeout: lock_timeout)
    end
  end

  def self.memory(hash: :sha1, &block)
    if block
      Database.memory(hash: hash, &block)
    else
      Database.memory(hash: hash)
    end
  end
end
