# frozen_string_literal: true

require_relative "conversion"

# Persistent collections with immutable snapshots and explicit transactions.
module XitDB
  # Owns the profile, history, and transactions of a public database.
  class Database
    # @!attribute [r] core
    #   Raw storage API for operations such as replication.
    #   @return [Core::Database]
    # @!attribute [r] profile
    #   Rules used to interpret values and collection keys.
    #   @return [Profiles::Portable, Profiles::Ruby]
    attr_reader :core, :profile

    # Resolve a portable hash algorithm and reject the reserved Ruby identifier.
    # @api private
    # @param value [Symbol, Core::Hasher] algorithm name or configured hasher
    # @return [Core::Hasher]
    # @raise [ProfileMismatchError] if the hasher uses a reserved Ruby profile identifier
    def self.hasher(value)
      if value.is_a?(Core::Hasher)
        if %w[rb01 rb02 rb03 rb04].include?(value.id)
          raise ProfileMismatchError, "#{value.id} is reserved for XitDB::Ruby"
        end

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

    # Open a portable database, creating a missing file.
    #
    # A profile defines which Ruby values a file can represent. Portable files
    # use the upstream xitdb rules. Ruby-profile files require {Ruby.open}.
    # With a block, the handle closes even if the block raises an exception.
    # Without a block, the caller must call {#close}.
    #
    # @param path [String] file to open or create
    # @param readonly [Boolean] forbid transactions and require an existing file
    # @param hash [Symbol, Core::Hasher, nil] hash configuration; nil reads the header or defaults to SHA-1
    # @param lock_timeout [Float] seconds to wait for the writer lock
    # @yield [database] use the database before automatic closure
    # @yieldparam database [Database] open handle
    # @return [Database, Object] handle without a block, otherwise the block's result
    # @raise [ProfileMismatchError] if the file uses an incompatible profile
    # @raise [CorruptionError] if the existing file has invalid storage data
    # @see XitDB.open
    def self.open(path, readonly: false, hash: nil, lock_timeout: 5.0)
      selected = hasher(hash) unless hash.nil?
      # @type var options: { ?hash_id: String, ?hash_size: Integer }
      options = selected ? { hash_id: selected.id, hash_size: selected.size } : {}
      store, created = open_store(path, readonly: readonly)
      begin
        core = Core::Database.new(store: store, initialize_empty: created, lock_timeout: lock_timeout, **options)
        if %w[rb01 rb02 rb03 rb04].include?(core.header.hash_id)
          raise ProfileMismatchError, "Ruby profile file requires XitDB::Ruby.open"
        end

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

    # Match the file's hash identifier and digest size to a builtin algorithm.
    # @param header [Core::Header]
    # @return [Core::Hasher]
    # @raise [ProfileMismatchError] if explicit configuration is required
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

    # Create exclusively first, so opening an existing empty file cannot initialize it.
    # @param path [String]
    # @param readonly [Boolean]
    # @return [Array(Core::FileStore, Boolean)] storage and whether this call created it
    def self.open_store(path, readonly:)
      return [Core::FileStore.open(path, readonly: true), false] if readonly

      begin
        [Core::FileStore.open(path, exclusive: true), true]
      rescue Errno::EEXIST
        [Core::FileStore.open(path, create: false), false]
      end
    end
    private_class_method :open_store

    # Create a portable database that stores bytes only in this process.
    #
    # Closing discards its data. The block form closes automatically.
    # @param hash [Symbol, Core::Hasher] portable hash algorithm
    # @yield [database] work with the temporary database
    # @yieldparam database [Database]
    # @return [Database, Object] handle or block result
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

    # Attach a value profile to storage and validate its public root.
    # @api private
    # @param core [Core::Database] owned storage handle
    # @param profile [Profiles::Portable, Profiles::Ruby] value interpretation
    # @param readonly [Boolean] disable public writes
    def initialize(core:, profile:, readonly: false)
      @core = core
      @profile = profile
      @readonly = readonly
      snapshot
    end

    # Change values together and return their committed snapshot.
    #
    # The root acts like a Hash. Nested collections are database views.
    # Normal completion commits changes; an exception aborts them.
    # The block's views expire when the transaction ends.
    # A transaction with no logical changes adds no history entry.
    #
    # @yield [root] make related changes under one writer lock
    # @yieldparam root [Views::Map] writable root map
    # @return [Snapshot] committed root, regardless of the block's return value
    # @raise [ReadOnlyError] if the handle forbids writes
    # @raise [BusyError] if the writer lock times out before the block runs
    # @raise [CommitError] if storage publication or synchronization fails
    # @raise [ArgumentError] if no block is supplied
    # @example Commit two related values
    #   db.transaction do |root|
    #     root["name"] = "Ada"
    #     root["visits"] = 1
    #   end
    # @see CommitError#outcome
    def transaction(&block)
      raise ArgumentError, "transaction requires a block" unless block_given?
      raise ReadOnlyError, "database is read-only" if @readonly

      core.with_operation { perform_transaction(&block) }
    end

    # Append a logical root only after the user's changes complete.
    # @yield [root] transaction's writable map
    # @yieldparam root [Views::Map]
    # @return [Snapshot] committed state
    def perform_transaction
      committed = core.transaction do |history_cursor|
        array = history_array(history_cursor)
        empty = array.size.zero? # rubocop:disable Style/ZeroLengthPredicate -- Core arrays expose size, not empty?.
        slot = empty ? Core::Slot.new : (array.get(-1) || raise(CorruptionError, "missing history root"))
        context = Context.new(database: self, root: slot, bound: history_cursor.bound,
                              transaction: history_cursor.transaction)
        validate_root!(slot, context) unless empty
        root = context.view(slot, path: [], kind: :map)
        yield root
        if context.changed?
          array.append(context.root)
        else
          context.writable_transaction!.cancel_publication
        end
      end
      snapshot_from_cursor(committed)
    end
    private :perform_transaction

    # Capture the latest root or resolve a saved revision.
    #
    # Later commits do not change this snapshot. Its views require an open handle.
    # @param revision [Revision, nil] saved position; nil selects the latest state
    # @return [Snapshot] read-only root
    # @raise [ForeignRevisionError] if the revision no longer identifies this file
    def snapshot(revision: nil)
      core.with_operation do
        if revision
          raise TypeError, "revision must be an XitDB::Revision" unless revision.is_a?(Revision)

          return revision.resolve(self)
        end
        snapshot_from_cursor(core.root_cursor)
      end
    end

    # Access committed roots in oldest-first order.
    # @return [History] live access to the database's history
    def history
      core.check_open!
      History.new(self)
    end

    # Append a previous root as a new commit without deleting history.
    # @param value [Snapshot, Revision] state from this file generation
    # @return [Snapshot] new commit containing the selected values
    # @raise [ForeignRevisionError] if the state belongs to another file generation
    # @raise [ReadOnlyError] if writes are forbidden
    def revert(value)
      core.with_operation { perform_revert(value) }
    end

    # Validate the selected root again under the writer lock before appending it.
    # @param value [Snapshot, Revision]
    # @return [Snapshot] newly published state
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

    # Close storage and invalidate every view that uses this handle.
    # @return [void]
    def close
      core.close
    end

    # Copy reachable storage to a separate file and return its open handle.
    #
    # Shared structures remain shared. Compaction preserves the stored profile.
    # The caller closes the returned database.
    # @param to [String] separate empty destination file
    # @return [Database] compacted database
    # @see #convert
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

    # Report whether this handle has closed.
    # @return [Boolean]
    def closed?
      core.closed?
    end

    # Copy logical values into a separate database with the selected profile.
    #
    # Conversion decodes and encodes values, so shared histories can duplicate data.
    # Use a transform when a value or key needs an explicit representation change.
    # The caller closes the returned database.
    #
    # @param to [String] separate empty destination file
    # @param profile [Symbol, Profiles::Portable, Profiles::Ruby] :portable, :ruby, or a configured profile
    # @param history [Symbol] :all copies every root; :latest copies only the last root
    # @param transform [#call, nil] callback receiving value:, path:, and role: (:key or :value)
    # @return [Database] converted database
    # @raise [UnsupportedValueError] if the destination cannot encode a value
    # @raise [KeyCollisionError] if different source keys become the same destination key
    # @see #compact
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
    # Read the physical array whose entries are committed logical root maps.
    # @api private
    # @param cursor [Core::Cursor]
    # @return [Core::ArrayList]
    # @raise [ProfileMismatchError] if the physical root is not a history array
    def history_array(cursor)
      unless cursor.slot.empty? || cursor.slot.tag == :array_list
        raise ProfileMismatchError, "public databases require a top-level history array"
      end

      Core::ArrayList.new(cursor)
    end

    # Build a read-only map from one entry in a captured history.
    # @api private
    # @param cursor [Core::Cursor]
    # @param index [Integer] history position
    # @param revision [Revision, nil] existing identity proof
    # @return [Snapshot]
    def snapshot_from_history(cursor, index, revision: nil)
      core.with_operation do
        slot = history_array(cursor).get(index)
        raise IndexError, "history index outside history" unless slot
        raise ProfileMismatchError, "history entry must contain a root map" if slot.empty?

        context = Context.new(database: self, root: slot, bound: cursor.bound)
        validate_root!(slot, context)
        revision ||= revision_for(cursor, index)
        Snapshot.new(context: context, revision: revision)
      end
    end

    private

    # Create an independent profile configuration for the destination.
    # @param selected [Symbol, Profiles::Portable, Profiles::Ruby]
    # @return [Profiles::Portable, Profiles::Ruby]
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

    # Copy selected roots in one destination transaction after checking target identity.
    # @param target [Database]
    # @param store [Core::FileStore]
    # @param captured [Core::Cursor] source commit boundary
    # @param histories [Core::ArrayList]
    # @param history [Symbol] :all or :latest
    # @param transform [#call, nil]
    # @return [Core::Cursor] committed destination cursor
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
          transaction = destination.writable_transaction!
          transaction.with_logical_mutation do
            output.append(Conversion.new(source, destination, transform: transform).copy(source.root))
            transaction.freeze
          end
        end
      end
    end

    # Require a logical root map after the selected profile interprets its storage.
    # @param slot [Core::Slot]
    # @param context [Context]
    # @return [void]
    def validate_root!(slot, context)
      adapter = profile.container(slot, context: context, path: []) unless slot.empty?
      return if adapter && %i[map sorted_map].include?(adapter.kind)

      raise ProfileMismatchError, "history entry must contain a root map"
    end

    # Select the latest history entry, or expose an empty uncommitted root.
    # @param cursor [Core::Cursor]
    # @return [Snapshot]
    def snapshot_from_cursor(cursor)
      count = history_array(cursor).size
      return snapshot_from_history(cursor, count - 1) unless count.zero?

      Snapshot.new(context: Context.new(database: self, root: Core::Slot.new, bound: cursor.bound), revision: nil)
    end

    # Bind a history index to the file identifier and commit trailer checksum.
    # @param cursor [Core::Cursor]
    # @param index [Integer]
    # @return [Revision]
    def revision_for(cursor, index)
      position = cursor.bound - Core::Database::TRAILER_SIZE
      checksum = core.read_at(position + 17, 8, bound: cursor.bound).unpack1("Q>")
      raise CorruptionError, "invalid history checksum" unless checksum.is_a?(Integer)

      Revision.new(file_id: core.header.file_id, trailer_position: position, checksum: checksum, index: index)
    end
  end

  # Open or create a portable database.
  #
  # Portable map keys are Strings. Use {Ruby.open} for native Ruby values.
  # @param path [String] database filename
  # @param readonly [Boolean] require an existing file and forbid writes
  # @param hash [Symbol, Core::Hasher, nil] algorithm or configuration; nil detects existing files
  # @param lock_timeout [Float] seconds allowed to acquire the writer lock
  # @yield [database] use a handle that closes when the block ends
  # @yieldparam database [Database]
  # @return [Database, Object] open handle or block result
  # @see Database.open
  def self.open(path, readonly: false, hash: nil, lock_timeout: 5.0, &block)
    if block
      Database.open(path, readonly: readonly, hash: hash, lock_timeout: lock_timeout, &block)
    else
      Database.open(path, readonly: readonly, hash: hash, lock_timeout: lock_timeout)
    end
  end

  # Create a portable database without a disk file.
  # @param hash [Symbol, Core::Hasher] hash algorithm
  # @yield [database] use a handle that closes when the block ends
  # @yieldparam database [Database]
  # @return [Database, Object] open handle or block result
  # @example Store and read a value
  #   XitDB.memory do |db|
  #     db.transaction { |root| root["score"] = 10 }
  #     db.snapshot["score"] # => 10
  #   end
  # @see Database.memory
  def self.memory(hash: :sha1, &block)
    if block
      Database.memory(hash: hash, &block)
    else
      Database.memory(hash: hash)
    end
  end
end
