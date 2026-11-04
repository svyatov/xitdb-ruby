# frozen_string_literal: true

require "monitor"

module XitDB
  module Core
    module Store
      def read_at(offset, length)
        synchronize do
          position(offset)
          position(length)
          next "".b if length.zero?
          raise EOFError, "read exceeds store length" if offset + length > store_length

          read_bytes(offset, length)
        end
      end

      def write_at(offset, bytes)
        synchronize do
          writable!
          position(offset)
          string(bytes)
          write_bytes(offset, bytes.b) unless bytes.empty?
          bytes.bytesize
        end
      end

      def append(bytes)
        synchronize do
          writable!
          offset = store_length
          write_at(offset, bytes)
          offset
        end
      end

      def length
        synchronize { store_length }
      end

      def truncate(length)
        synchronize do
          writable!
          position(length)
          truncate_bytes(length)
          nil
        end
      end

      def flush
        synchronize { flush_bytes }
      end

      def sync
        synchronize do
          flush_bytes
          sync_bytes
        end
      end

      # Pin the handle across all storage calls in one logical operation.
      def with_operation
        thread = Thread.current
        synchronize { @operation_users[thread] = @operation_users.fetch(thread, 0) + 1 }
        begin
          yield
        ensure
          @state.synchronize do
            @operation_users[thread] -= 1
            @operation_users.delete(thread) if @operation_users[thread].zero?
            @idle.broadcast
          end
        end
      end

      def with_exclusive_lock(timeout: 5, on_release_error: nil)
        raise TypeError, "timeout must be a real Numeric" unless timeout.is_a?(Numeric) && timeout.real?
        raise ArgumentError, "timeout must be finite and nonnegative" unless timeout.finite? && timeout >= 0

        deadline = monotonic_time + timeout
        synchronize do
          writable!
          raise TransactionStateError, "writer lock is already held by this thread" if @lock_owner == Thread.current

          @lock_users += 1
        end
        locked = false
        completed = false
        begin
          lock_writer(deadline)
          locked = true
          @state.synchronize do
            writable!
            @lock_owner = Thread.current
          end
          result = yield
          completed = true
          result
        ensure
          begin
            @state.synchronize do
              @lock_owner = nil if locked
              begin
                unlock_writer if locked
              rescue Exception => error
                @release_failed = true
                on_release_error&.call(error)
                # Raising here would replace a pending exception or nonlocal exit.
                raise if completed
              end
            end
          ensure
            @state.synchronize do
              @lock_users -= 1
              @idle.broadcast
            end
          end
        end
      end

      def close
        @state.synchronize do
          return if @closed
          raise TransactionStateError, "cannot close inside the writer block" if @lock_owner == Thread.current
          if @operation_users.key?(Thread.current)
            raise TransactionStateError, "cannot close inside an active operation"
          end

          @closing = true
          begin
            @idle.wait until @lock_users.zero? && @operation_users.empty?
            return if @closed

            flush_bytes
            close_bytes
            @closed = true
          ensure
            @closing = false
          end
        end
      end

      def closed?
        @state.synchronize { @closed }
      end

      private

      def initialize_state(writer_mutex = Mutex.new)
        @state = Monitor.new
        @idle = @state.new_cond
        @writer_mutex = writer_mutex
        @lock_users = 0
        @operation_users = {}
        @lock_owner = nil
        @closed = false
        @closing = false
        @release_failed = false
      end

      def synchronize
        @state.synchronize do
          if @closed || (@closing && @lock_owner != Thread.current && !@operation_users.key?(Thread.current))
            raise ClosedError, "store is closed"
          end

          yield
        end
      end

      def writable!
        raise ReadOnlyError, "store is read-only" if readonly?
        raise TransactionStateError, "writer lock release failed; reopen the store" if @release_failed
      end

      def position(value)
        raise TypeError, "offset and length must be Integers" unless value.is_a?(Integer)
        raise ArgumentError, "offset and length must be nonnegative" if value.negative?
      end

      def string(bytes)
        raise TypeError, "bytes must be a String" unless bytes.is_a?(String)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def wait_for_writer(deadline)
        remaining = deadline - monotonic_time
        raise BusyError, "writer lock timed out" unless remaining.positive?

        sleep([remaining, 0.005].min)
      end

      def lock_writer(deadline)
        wait_for_writer(deadline) until @writer_mutex.try_lock
      end

      def unlock_writer
        @writer_mutex.unlock
      end
    end
    private_constant :Store

    class MemoryStore
      include Store

      attr_reader :storage_identity

      def initialize(bytes = "".b)
        string(bytes)
        @bytes = bytes.b
        @storage_identity = Object.new.freeze
        initialize_state
      end

      def readonly?
        false
      end

      private

      def store_length
        @bytes.bytesize
      end

      def read_bytes(offset, length)
        @bytes.byteslice(offset, length)
      end

      def write_bytes(offset, bytes)
        @bytes << "\0".b * (offset - store_length) if offset > store_length
        @bytes[offset, bytes.bytesize] = bytes
      end

      def truncate_bytes(length)
        if length < store_length
          @bytes = @bytes.byteslice(0, length)
        else
          @bytes << "\0".b * (length - store_length)
        end
      end

      def flush_bytes; end

      def sync_bytes; end

      def close_bytes
        @bytes.clear
      end
    end
  end
end
