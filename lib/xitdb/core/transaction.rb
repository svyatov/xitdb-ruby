# frozen_string_literal: true

module XitDB
  module Core
    # Writable state owned by one database transaction and one thread.
    #
    # A checkpoint saves cursors and file length. Restoring it removes later writes and expires later cursors.
    #
    # Copy-on-write preserves earlier views by copying blocks below mutable_start before changing them.
    class Transaction
      Checkpoint = Struct.new(:owner, :slots, :length, :cancelled, keyword_init: true) # rubocop:disable Lint/StructNewOverride -- Length is the saved store boundary.
      private_constant :Checkpoint

      # @!attribute [r] root
      #   Writable root cursor for the active transaction.
      #   @return [Cursor]
      # @!attribute [r] mutable_start
      #   First byte offset that can be changed without copying protected records.
      #   @return [Integer]
      attr_reader :root, :mutable_start

      # Starts thread-owned writable state from the current root slot.
      # @param database [Database] database that owns the stored records
      # @param store [MemoryStore, FileStore] underlying byte storage
      # @param slot [Slot] stored value or record descriptor
      # @return [Transaction]
      def initialize(database, store, slot)
        @database = database
        @store = store
        @owner = Thread.current
        @active = true
        @cancelled = false
        @cursors = ObjectSpace::WeakMap.new
        @checkpoints = []
        @mutable_start = store.length
        @root = cursor(slot: slot)
      end

      # Checks that the database is open and this transaction belongs to the calling thread.
      # @return [void]
      # @raise [ClosedError] if the database is closed
      # @raise [ExpiredViewError] if the transaction has ended
      # @raise [TransactionStateError] if called from another thread
      def check_active!
        @database.check_open!
        raise ExpiredViewError, "transaction has ended" unless @active
        raise TransactionStateError, "transaction belongs to another thread" unless @owner == Thread.current
      end

      # Rejects a nested logical mutation inside this transaction.
      # @return [void]
      # @raise [TransactionStateError] if a logical mutation is already running
      # @api private
      def check_logical_mutation!
        check_active!
        raise TransactionStateError, "a logical mutation is already active" if @logical_mutation
      end

      # Runs one logical mutation and clears its guard even when the block fails.
      # @return [Object]
      # @yield runs with the logical mutation guard held
      # @yieldreturn [Object] result returned to the caller
      # @api private
      def with_logical_mutation
        check_logical_mutation!
        @logical_mutation = true
        begin
          yield
        ensure
          @logical_mutation = false
        end
      end

      # Creates and registers a writable cursor for a slot.
      # @param slot [Slot] stored value or record descriptor
      # @return [Cursor]
      def cursor(slot:)
        check_active!
        validate_slot!(slot)
        cursor = Cursor.new(database: @database, slot: slot, bound: length, transaction: self)
        @cursors[cursor] = true
        cursor
      end

      # Checks that a cursor still belongs to this transaction state.
      # @param cursor [Cursor] view locating this collection or value
      # @return [void]
      # @raise [ExpiredViewError] if rollback discarded the cursor
      # @api private
      def check_cursor!(cursor)
        check_active!
        raise ExpiredViewError, "cursor was discarded by restore" unless @cursors.key?(cursor)
      end

      # Checks cursor ownership and validates its replacement slot.
      # @param cursor [Cursor] view locating this collection or value
      # @param value [Slot] replacement slot to validate
      # @return [void]
      # @api private
      def check_replacement!(cursor, value)
        check_cursor!(cursor)
        validate_slot!(value)
      end

      # Returns the storage length visible to this transaction.
      # @return [Integer]
      def length
        check_active!
        @store.length
      end

      # Appends bytes and returns the absolute offset of the added data.
      # @param bytes [String] binary input bytes
      # @return [Integer]
      def append(bytes)
        check_active!
        @store.append(bytes)
      end

      # Reads bytes within the transaction's current storage boundary.
      # @param offset [Integer] absolute byte offset
      # @param size [Integer] number of bytes
      # @return [String]
      def read_at(offset, size)
        check_active!
        @database.read_at(offset, size, bound: length)
      end

      # Changes allocated bytes at or above the copy-on-write boundary.
      # @param offset [Integer] absolute byte offset
      # @param bytes [String] binary input bytes
      # @return [Integer]
      # @raise [TransactionStateError] if offset is below mutable_start
      # @raise [RangeError] if the write extends beyond allocated data
      def write_at(offset, bytes)
        check_active!
        raise TransactionStateError, "write requires copy-on-write" if offset < @mutable_start
        raise RangeError, "write exceeds allocated data" if offset + bytes.bytesize > length

        @store.write_at(offset, bytes)
      end

      # Moves the copy-on-write boundary to the current storage end.
      # @return [Integer]
      # @note This protects stored blocks. It does not call Object#freeze on the transaction.
      def freeze
        check_active!
        @mutable_start = length
      end

      # Saves cursor states and storage length for a later rollback.
      # @return [Checkpoint]
      def checkpoint
        check_active!
        # @type var slots: Hash[Cursor, cursor_state]
        slots = {}
        @cursors.each_key { |cursor| slots[cursor] = cursor.checkpoint_state }
        checkpoint = Checkpoint.new(owner: self, slots: slots, length: freeze, cancelled: @cancelled).freeze
        @checkpoints << checkpoint
        checkpoint
      end

      # Rolls back bytes and cursors, consuming the supplied checkpoint and newer checkpoints.
      # @param checkpoint [Checkpoint] live rollback state created by this transaction
      # @return [nil]
      # @raise [TransactionStateError] if the checkpoint is foreign, consumed, or no longer valid
      # @note Cursors created after this checkpoint become expired views.
      def restore(checkpoint)
        check_active!
        index = @checkpoints.index { |item| item.equal?(checkpoint) }
        unless index && checkpoint.owner.equal?(self) && checkpoint.length <= length
          raise TransactionStateError, "checkpoint does not belong to this transaction state"
        end

        @store.truncate(checkpoint.length)
        @cursors = ObjectSpace::WeakMap.new
        checkpoint.slots.each do |cursor, state|
          @cursors[cursor] = true
          cursor.restore_checkpoint_state(state)
        end
        @mutable_start = checkpoint.length
        @cancelled = checkpoint.cancelled
        (@checkpoints.slice!(index..) || []).each { |item| item.slots.clear }
        nil
      end

      # Discards rollback state after a successful internal operation.
      # @param checkpoint [Checkpoint] live rollback state created by this transaction
      # @return [nil]
      # @raise [TransactionStateError] if the checkpoint belongs to another transaction
      # @api private
      def release_checkpoint(checkpoint)
        check_active!
        unless checkpoint.is_a?(Checkpoint) && checkpoint.owner.equal?(self)
          raise TransactionStateError, "checkpoint belongs to another transaction"
        end

        @checkpoints.delete_if { |item| item.equal?(checkpoint) }
        checkpoint.slots.clear
        nil
      end

      # Marks this transaction so its root will not be committed.
      # @return [Boolean]
      def cancel_publication
        check_active!
        @cancelled = true
      end

      # Tests whether root publication has been cancelled.
      # @return [Boolean]
      def cancelled?
        check_active!
        @cancelled
      end

      # Ends the transaction and discards registered cursors and checkpoints.
      # @return [void]
      # @api private
      def expire!
        @active = false
        @checkpoints.each { |checkpoint| checkpoint.slots.clear }
        @checkpoints.clear
        @cursors = ObjectSpace::WeakMap.new
        @root = nil
      end

      private

      # Rejects values that are not slots with a recognized tag.
      def validate_slot!(slot)
        raise TypeError, "expected Slot" unless slot.is_a?(Slot)
        raise CorruptionError, "unknown slot tag" unless Slot::TAGS.include?(slot.tag)
      end
    end
  end
end
