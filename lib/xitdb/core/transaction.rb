# frozen_string_literal: true

module XitDB
  module Core
    class Transaction
      Checkpoint = Struct.new(:owner, :slots, :length, :cancelled, keyword_init: true)
      private_constant :Checkpoint

      attr_reader :root, :mutable_start

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

      def check_active!
        @database.check_open!
        raise ExpiredViewError, "transaction has ended" unless @active
        raise TransactionStateError, "transaction belongs to another thread" unless @owner == Thread.current
      end

      def cursor(slot:)
        check_active!
        validate_slot(slot)
        cursor = Cursor.new(database: @database, slot: slot, bound: length, transaction: self)
        @cursors[cursor] = true
        cursor
      end

      def check_cursor!(cursor)
        check_active!
        raise ExpiredViewError, "cursor was discarded by restore" unless @cursors.key?(cursor)
      end

      def check_replacement!(cursor, value)
        check_cursor!(cursor)
        validate_slot(value)
      end

      def length
        check_active!
        @store.length
      end

      def append(bytes)
        check_active!
        @store.append(bytes)
      end

      def read_at(offset, size)
        check_active!
        @database.read_at(offset, size, bound: length)
      end

      # Collections must copy blocks below this boundary before changing them.
      def write_at(offset, bytes)
        check_active!
        raise TransactionStateError, "write requires copy-on-write" if offset < @mutable_start
        raise RangeError, "write exceeds allocated data" if offset + bytes.bytesize > length

        @store.write_at(offset, bytes)
      end

      def freeze
        check_active!
        @mutable_start = length
      end

      def checkpoint
        check_active!
        slots = {}
        @cursors.each_key { |cursor| slots[cursor] = cursor.slot }
        checkpoint = Checkpoint.new(owner: self, slots: slots, length: freeze, cancelled: @cancelled).freeze
        @checkpoints << checkpoint
        checkpoint
      end

      def restore(checkpoint)
        check_active!
        index = @checkpoints.index { |item| item.equal?(checkpoint) }
        unless index && checkpoint.owner.equal?(self) && checkpoint.length <= length
          raise TransactionStateError, "checkpoint does not belong to this transaction state"
        end

        @store.truncate(checkpoint.length)
        @cursors = ObjectSpace::WeakMap.new
        checkpoint.slots.each do |cursor, slot|
          @cursors[cursor] = true
          cursor.replace(slot)
        end
        @mutable_start = checkpoint.length
        @cancelled = checkpoint.cancelled
        @checkpoints.slice!(index..).each { |item| item.slots.clear }
        nil
      end

      # Internal operations release rollback state after a successful mutation.
      def release_checkpoint(checkpoint)
        check_active!
        unless checkpoint.is_a?(Checkpoint) && checkpoint.owner.equal?(self)
          raise TransactionStateError, "checkpoint belongs to another transaction"
        end

        @checkpoints.delete_if { |item| item.equal?(checkpoint) }
        checkpoint.slots.clear
        nil
      end

      def cancel_publication
        check_active!
        @cancelled = true
      end

      def cancelled?
        check_active!
        @cancelled
      end

      def expire!
        @active = false
        @checkpoints.each { |checkpoint| checkpoint.slots.clear }
        @checkpoints.clear
        @cursors = ObjectSpace::WeakMap.new
        @root = nil
      end

      private

      def validate_slot(slot)
        raise TypeError, "expected Slot" unless slot.is_a?(Slot)
        raise CorruptionError, "unknown slot tag" unless Slot::TAGS.include?(slot.tag)
      end
    end
  end
end
