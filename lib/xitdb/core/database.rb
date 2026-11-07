# frozen_string_literal: true

require "securerandom"
require_relative "compaction"
require_relative "replication"

module XitDB
  module Core
    # The advanced API for binary storage, root slots, and atomic transactions.
    #
    # Most applications use XitDB::Database, which converts Ruby values to slots.
    #
    # Each commit appends records and a checked root trailer, then publishes the new root.
    #
    # Read-only root cursors retain their original byte boundary while later transactions append data.
    #
    # @example Store a scalar root through the advanced API
    #   database = XitDB::Core::Database.memory
    #   database.transaction { |root| root.replace(XitDB::Core::Slot.uint(7)) }
    #   database.root_cursor.slot.value # => 7
    #   database.close
    class Database
      include Replication

      # Byte offset of the published root slot and committed length.
      ROOT_OFFSET = 20
      # First byte offset available for appended object records.
      DATA_OFFSET = 37
      # Bytes in a root trailer: slot, commit identifier, and checksum.
      TRAILER_SIZE = 25
      # Bytes in an initialized database containing an empty root and its trailer.
      MINIMUM_SIZE = 62

      # @!attribute [r] header
      #   Validated immutable file profile.
      #   @return [Header]
      attr_reader :header

      # Opens a database file and closes it after an optional block.
      # @param path [String] database file path
      # @param readonly [Boolean] whether to reject writes
      # Additional keyword options are forwarded to {#initialize}.
      # @return [Database, Object]
      # @yield [database] uses the database before automatic close
      # @yieldparam database [Database] opened database
      # @yieldreturn [Object] result returned by open when a block is supplied
      # @see #initialize
      def self.open(path, readonly: false, **)
        store = FileStore.open(path, readonly: readonly)
        begin
          database = new(store: store, **)
        rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
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

      # Creates an empty database that stores all bytes in memory.
      # @param hash_size [Integer] number of bytes in each stored digest
      # @param hash_id [String] four-byte hash algorithm identifier
      # @param file_id [Integer, nil] unsigned 64-bit file identifier; nil uses the stored value or creation default
      # @return [Database]
      def self.memory(hash_size: 20, hash_id: "sha1", file_id: nil)
        new(store: MemoryStore.new, hash_size: hash_size, hash_id: hash_id, file_id: file_id)
      end

      # Creates an open database from a complete replication stream.
      # @param to [String] destination file path, which must be empty or absent
      # @param source_io [#read] binary reader implementing read(length)
      # @param length [Integer] number of bytes
      # @return [Database]
      # @see Replication.copy_replica
      def self.copy_replica(to:, source_io:, length:)
        Replication.copy_replica(to: to, source_io: source_io, length: length)
      end

      # Validates an existing store or initializes an empty writable store.
      # @param store [MemoryStore, FileStore] underlying byte storage
      # @param hash_size [Integer, nil] number of bytes in each stored digest; nil uses the stored value or creation
      #   default
      # @param hash_id [String, nil] four-byte hash algorithm identifier; nil uses the stored value or creation default
      # @param file_id [Integer, nil] unsigned 64-bit file identifier; nil uses the stored value or creation default
      # @param lock_timeout [Float] maximum wait for the exclusive writer lock, in seconds
      # @param initialize_empty [Boolean] whether an empty writable store may be initialized
      # @param require_empty [Boolean] whether opening must reject a nonempty store
      # @return [Database]
      # @raise [CorruptionError] if the header, root, or existing empty store is invalid
      # @raise [ProfileMismatchError] if supplied profile fields differ from the stored header
      # @raise [ArgumentError] if require_empty is true and the store contains data
      def initialize(store:, hash_size: nil, hash_id: nil, file_id: nil, lock_timeout: 5.0, initialize_empty: true,
                     require_empty: false)
        @store = store
        @lock_timeout = lock_timeout
        @needs_reopen = false
        @transaction = nil
        initialize_file = lambda do
          prepare_file(hash_size, hash_id, file_id, initialize_empty, require_empty)
        end
        if store.readonly?
          initialize_file.call
        else
          store.with_exclusive_lock(timeout: lock_timeout, &initialize_file)
        end
      rescue EOFError => e
        raise CorruptionError, e.message
      end

      # Closes the store after active operations and writers finish.
      # @return [void]
      def close
        @store.close
      end

      # Tests whether the underlying store is closed.
      # @return [Boolean]
      def closed?
        @store.closed?
      end

      # Keeps storage open throughout a multi-call operation.
      # @return [Object]
      # @yield runs while database close waits
      # @yieldreturn [Object] result returned to the caller
      # @api private
      def with_operation(&)
        @store.with_operation(&)
      end

      # Returns the identity used to detect shared underlying storage.
      # @return [Object, Array<Integer>]
      def storage_identity
        check_open!
        @store.storage_identity
      end

      # Tests whether a storage failure requires reopening before another write.
      # @return [Boolean]
      def needs_reopen?
        @needs_reopen
      end

      # Rejects operations after the database closes.
      # @return [void]
      # @raise [ClosedError] if the database has been closed
      # @api private
      def check_open!
        raise ClosedError, "database is closed" if closed?
      end

      # Returns the byte boundary of the last validated committed root.
      # @return [Integer]
      def committed_size
        committed_state.first
      end

      # Copies the current reachable value to an empty target with a new file identifier.
      # @param to [String] destination file path, which must be empty or absent
      # @return [Database]
      # @note An array-list root is treated as history; only its latest element is retained.
      # @raise [ArgumentError] if the target is nonempty or identifies the source file
      def compact(to:)
        with_operation do
          # @type var offsets_for_cleanup: OffsetMap?
          offsets_for_cleanup = nil
          # @type var target_for_cleanup: Database?
          target_for_cleanup = nil
          source = root_cursor
          slot = source.slot
          history = slot.tag == :array_list
          slot = ArrayList.new(source).get(-1) || Slot.new if history
          store = FileStore.open(to)
          begin
            raise ArgumentError, "compaction target is the source file" if store.storage_identity == storage_identity

            file_id = random_id
            file_id = random_id while file_id == header.file_id
            target = Database.new(store: store, hash_id: header.hash_id, hash_size: header.hash_size, file_id: file_id,
                                  lock_timeout: @lock_timeout, require_empty: true)
            target_for_cleanup = target
            offsets = OffsetMap.new
            offsets_for_cleanup = offsets
            unless slot.empty?
              copy_compacted_root(target, store, file_id, source, slot, history, offsets)
              published = true
            end
            offsets.close
            offsets_for_cleanup = nil
            completed = true
            target
          ensure
            cleanup_compaction(store, target_for_cleanup, offsets_for_cleanup, published) unless completed
          end
        end
      end

      # Creates a read-only view of the last validated committed root.
      # @return [Cursor]
      def root_cursor
        size, slot = committed_state
        Cursor.new(database: self, slot: slot, bound: size)
      end

      # Runs a writable root block, then commits and returns a fresh read-only root.
      # @return [Cursor]
      # @yield [root] changes the transaction-owned root
      # @yieldparam root [Cursor] writable root, valid only inside the block
      # @yieldreturn [Object] ignored; changes to root determine the committed value
      # @raise [BusyError] if the writer lock cannot be acquired in time
      # @raise [TransactionStateError] if writes require reopening or a nested writer is attempted
      # @raise [CommitError] if storage fails; inspect its outcome before retrying
      # @note Exceptions and nonlocal exits from the block do not publish its root.
      def transaction
        check_open!
        raise TransactionStateError, "database requires reopening" if @needs_reopen

        callback_completed = false
        # @type var callback_error: Exception?
        callback_error = nil
        # @type var outcome: :not_committed | :committed | :unknown
        outcome = :not_committed
        @store.with_exclusive_lock(timeout: @lock_timeout, on_release_error: ->(_error) { @needs_reopen = true }) do
          raise TransactionStateError, "database requires reopening" if @needs_reopen

          size, slot = committed_state
          @store.truncate(size) if @store.length > size
          transaction = Transaction.new(self, @store, slot)
          @transaction = transaction
          begin
            begin
              yield transaction.root
            rescue Exception => e # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
              callback_error = e
              raise
            end
            callback_completed = true
            unless transaction.cancelled?
              publish(transaction.root.slot, random_id)
              outcome = :committed
            end
          ensure
            finish_transaction(transaction, size, outcome, callback_completed, $!) # rubocop:disable Style/SpecialGlobalVars -- Preserve the pending exception during cleanup.
          end
          root_cursor
        end
      rescue Exception => e # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
        handle_transaction_error(e, callback_error, callback_completed, outcome || :not_committed)
      end

      # Preserves caller failures and reports storage failures with their commit outcome.
      def handle_transaction_error(error, callback_error, callback_completed, outcome)
        if callback_error && !error.equal?(callback_error)
          @needs_reopen = true
          raise callback_error, cause: callback_error.cause
        end
        raise error if error.is_a?(CommitError) || !callback_completed

        @needs_reopen = true
        raise CommitError.new(error.message, outcome: outcome), cause: error
      end
      private :handle_transaction_error

      # Allocates a byte value inside the active transaction.
      # @param data [String] payload bytes
      # @param format_tag [String, nil] optional two-byte application format identifier
      # @param prefix [String] owned bytes prepended without joining the full payload
      # @return [Slot]
      # @raise [TransactionStateError] if no active transaction exists
      def bytes(data, format_tag: nil, prefix: "".b)
        transaction = active_transaction!
        value = ByteValue.new(data, format_tag: format_tag)
        prefix = ByteValue.new(prefix).bytes
        Bytes.append(transaction, size: value.bytes.bytesize, format_tag: value.format_tag,
                                  prefix: prefix) do |position, length|
          Format.slice(value.bytes, position, length)
        end
      end

      # Loads a byte slot and its optional format tag inside a read boundary.
      # @param slot [Slot] stored value or record descriptor
      # @param bound [Integer, nil] exclusive upper byte boundary for reads; nil uses committed_size
      # @return [ByteValue]
      # @raise [InvalidValueError] if slot does not contain bytes
      def read_bytes(slot, bound: nil)
        check_open!
        bound ||= committed_size
        source = Bytes.open(self, slot, bound: bound)
        ByteValue.new(source.read(0, source.size), format_tag: source.format_tag)
      end

      # Reads allocated data inside a checked database boundary.
      # @param offset [Integer] absolute byte offset
      # @param size [Integer] number of bytes
      # @param bound [Integer] exclusive upper byte boundary for reads
      # @return [String]
      # @raise [CorruptionError] if the range is outside stored object data or its bound
      def read_at(offset, size, bound:)
        check_open!
        check_range!(offset, size, bound)
        @store.read_at(offset, size)
      rescue EOFError => e
        raise CorruptionError, e.message
      end

      private

      # Checks target ownership and publishes a copied root, retaining the history container when present.
      def copy_compacted_root(target, store, file_id, source, slot, history, offsets)
        target.transaction do |root|
          current = Header.parse(store.read_at(0, Header::SIZE))
          unless current.file_id == file_id && root.bound == MINIMUM_SIZE && root.slot.empty?
            raise ArgumentError, "compaction target changed before copying"
          end

          transaction = root.transaction
          raise TransactionStateError, "missing compaction transaction" unless transaction

          copier = Compaction.new(self, source, transaction, offsets)
          if history
            ArrayList.new(root).append(copier.copy(slot))
          else
            root.replace(copier.copy(slot))
          end
        end
      end

      # Closes scratch resources and restores an unpublished empty target when safe.
      def cleanup_compaction(store, target, offsets, published)
        begin
          offsets&.close
        rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
          nil
        end
        target&.restore_empty_target unless published
        store.send(:close_unreturned)
      end

      # Expires writable views and removes uncommitted data when rollback remains safe.
      def finish_transaction(transaction, size, outcome, callback_completed, pending_error)
        transaction.expire!
        @transaction = nil
        # Cleanup must preserve caller exceptions and nonlocal exits.
        return unless outcome == :not_committed && !@needs_reopen

        begin
          @store.truncate(size)
        rescue Exception => e # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
          @needs_reopen = true
          if callback_completed && pending_error.nil?
            raise CommitError.new(e.message, outcome: :not_committed), cause: e
          end
        end
      end

      # Checks profile compatibility or initializes an allowed empty store.
      def prepare_file(hash_size, hash_id, file_id, initialize_empty, require_empty)
        raise ArgumentError, "compaction target must be empty" if require_empty && !@store.empty?

        if @store.empty?
          raise CorruptionError, "empty read-only database" if @store.readonly?
          raise CorruptionError, "existing empty database" unless initialize_empty

          initialize_empty_file(hash_size, hash_id, file_id, require_empty)
        else
          @header = Header.parse(@store.read_at(0, Header::SIZE))
          check_header!(:hash_size, hash_size, @header.hash_size)
          check_header!(:hash_id, hash_id, @header.hash_id)
          check_header!(:file_id, file_id, @header.file_id)
          committed_state
        end
      end

      # Writes the format header and publishes the initial empty root.
      def initialize_empty_file(hash_size, hash_id, file_id, require_empty)
        @header = Header.new(hash_size: hash_size || 20, hash_id: hash_id || "sha1", file_id: file_id || random_id)
        @store.write_at(0, @header.to_bytes + ("\0".b * 17))
        publish(Slot.new, 0)
      rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
        reset_failed_initialization(require_empty)
        raise
      end

      # Truncates a failed private target while its initialization lock is held.
      def reset_failed_initialization(require_empty)
        # The exclusive initialization lock still owns this empty target.
        @store.truncate(0) if require_empty && !@needs_reopen
      rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
        nil
      end

      # Rejects a requested profile value that differs from the file header.
      def check_header!(name, expected, actual)
        return if expected.nil? || expected == actual

        raise ProfileMismatchError, "#{name} does not match the database header"
      end

      # Closes a database handle that failed before it could be returned.
      def close_unreturned
        @store.send(:close_unreturned)
      end

      # Restores an unpublished target only while its file generation and empty root still match.
      def restore_empty_target
        return if needs_reopen?

        @store.with_exclusive_lock(timeout: @lock_timeout) do
          current = Header.parse(@store.read_at(0, Header::SIZE))
          next unless current.file_id == header.file_id

          size, slot = committed_state
          @store.truncate(0) if size == MINIMUM_SIZE && slot.empty?
        end
      rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
        # Cleanup must preserve the original failure or nonlocal exit. A new
        # generation or committed root belongs to its writer and is retained.
        nil
      end

      protected :restore_empty_target

      # Returns the active transaction after checking thread ownership.
      def active_transaction!
        transaction = @transaction
        raise TransactionStateError, "allocation requires a transaction" unless transaction

        transaction.check_active!
        transaction
      end

      # Rejects data reads outside the object region and read boundary.
      def check_range!(offset, size, bound)
        unless offset.is_a?(Integer) && size.is_a?(Integer) && bound.is_a?(Integer) &&
               offset >= DATA_OFFSET && size >= 0 && offset + size <= bound
          raise CorruptionError, "object exceeds its read boundary"
        end
      end

      # Validates the published byte boundary and its root trailer.
      def committed_state
        check_open!
        size = Format.unsigned(@store.read_at(ROOT_OFFSET + Slot::SIZE, 8))
        raise CorruptionError, "invalid committed file size" if size < MINIMUM_SIZE || size > @store.length

        slot, = Replication.trailer(@store, header, size, size)
        [size, slot]
      rescue EOFError => e
        raise CorruptionError, e.message
      end

      # Synchronizes an appended root trailer before publishing and synchronizing the root pointer.
      def publish(slot, commit_id)
        # @type var outcome: :not_committed | :committed | :unknown
        outcome = :not_committed
        position = @store.length
        body = slot.to_bytes + [commit_id].pack("Q>")
        checksum = CRC64.call([header.file_id, position].pack("Q>Q>") + body)
        @store.append(body + [checksum].pack("Q>"))
        @store.sync
        outcome = :unknown
        @store.write_at(ROOT_OFFSET, slot.to_bytes + [position + TRAILER_SIZE].pack("Q>"))
        @store.sync
      rescue Exception => e # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
        @needs_reopen = true if outcome == :unknown
        raise CommitError.new(e.message, outcome: outcome || :not_committed), cause: e
      end

      # Generates an unsigned 64-bit identifier from random bytes.
      def random_id
        Format.unsigned(SecureRandom.random_bytes(8))
      end
    end
  end
end
