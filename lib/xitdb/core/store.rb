# frozen_string_literal: true

module XitDB
  module Core
    # Shared locking, byte access, and close coordination for storage handles.
    #
    # A logical operation keeps the handle open across several reads or writes.
    #
    # A writer lock permits one writer at a time. A flush drains buffers; sync also requests durable storage.
    # @api private
    module Store
      # Closes an owned store after failure, preserving the original exception.
      def close_unreturned
        close
      rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
        begin
          close(discard: true)
        rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
          nil
        end
      end
      private :close_unreturned

      # Reads exactly the requested bytes at an absolute offset.
      # @param offset [Integer] absolute byte offset
      # @param length [Integer] number of bytes
      # @return [String]
      # @raise [EOFError] if the requested range exceeds store length
      # @raise [ClosedError] if the store is closed
      def read_at(offset, length)
        synchronize do
          position(offset)
          position(length)
          next "".b if length.zero?
          raise EOFError, "read exceeds store length" if offset + length > store_length

          read_bytes(offset, length)
        end
      end

      # Writes bytes at an absolute offset and returns their count.
      # @param offset [Integer] absolute byte offset
      # @param bytes [String] binary input bytes
      # @return [Integer]
      # @raise [ReadOnlyError] if the store is read-only
      # @raise [ClosedError] if the store is closed
      def write_at(offset, bytes)
        synchronize do
          writable!
          position(offset)
          string(bytes)
          write_bytes(offset, bytes.b) unless bytes.empty?
          bytes.bytesize
        end
      end

      # Adds bytes at the logical end and returns their starting offset.
      # @param bytes [String] binary input bytes
      # @return [Integer]
      def append(bytes)
        synchronize do
          writable!
          offset = store_length
          write_at(offset, bytes)
          offset
        end
      end

      # Counts logical bytes, including buffered writes.
      # @return [Integer]
      def length
        synchronize { store_length }
      end

      # Tests whether the store contains zero bytes.
      # @return [Boolean]
      def empty?
        length.zero?
      end

      # Sets the logical length, removing bytes or adding zero bytes.
      # @param length [Integer] number of bytes
      # @return [nil]
      def truncate(length)
        synchronize do
          writable!
          position(length)
          truncate_bytes(length)
          nil
        end
      end

      # Sends buffered writes to the underlying storage.
      # @return [void]
      def flush
        synchronize { flush_bytes }
      end

      # Flushes writes and requests durable storage where supported.
      # @return [void]
      def sync
        synchronize do
          flush_bytes
          sync_bytes
        end
      end

      # Keeps the store open throughout one multi-call operation.
      # @return [Object]
      # @yield runs while close waits for this operation
      # @yieldreturn [Object] result returned to the caller
      # @api private
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

      # Runs one writer while other writers wait until the timeout.
      # @param timeout [Numeric] finite nonnegative number of seconds to wait for a writer
      # @param on_release_error [Proc, nil] optional callback receiving a writer lock release exception
      # @return [Object]
      # @yield runs while this thread owns the writer lock
      # @yieldreturn [Object] result returned to the caller
      # @raise [BusyError] if another writer holds the lock past the timeout
      # @raise [TransactionStateError] if this thread already holds the writer lock
      # @raise [ReadOnlyError] if the store is read-only
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
            release_writer(locked, completed, on_release_error)
          ensure
            @state.synchronize do
              @lock_users -= 1
              @idle.broadcast
            end
          end
        end
      end

      # Waits for operations and writers, then closes the store.
      # @param discard [Boolean] whether to close without flushing buffered writes
      # @return [void]
      # @raise [TransactionStateError] if called inside this thread's active operation or writer block
      def close(discard: false)
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

            flush_bytes unless discard
            close_bytes
            @closed = true
          ensure
            @closing = false
          end
        end
      end

      # Tests whether the store has completed closing.
      # @return [Boolean]
      def closed?
        @state.synchronize { @closed }
      end

      private

      # Releases writer ownership and preserves a pending caller failure.
      def release_writer(locked, completed, on_release_error)
        @state.synchronize do
          @lock_owner = nil if locked
          begin
            unlock_writer if locked
          rescue Exception => e # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
            @release_failed = true
            on_release_error&.call(e)
            # Raising here would replace a pending exception or nonlocal exit.
            raise if completed
          end
        end
      end

      # Creates the monitor, operation counters, and shared writer mutex.
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

      # Checks the store lifetime while holding its state monitor.
      def synchronize
        @state.synchronize do
          if @closed || (@closing && @lock_owner != Thread.current && !@operation_users.key?(Thread.current))
            raise ClosedError, "store is closed"
          end

          yield
        end
      end

      # Rejects read-only writes and writes after a failed lock release.
      def writable!
        raise ReadOnlyError, "store is read-only" if readonly?
        raise TransactionStateError, "writer lock release failed; reopen the store" if @release_failed
      end

      # Rejects offsets and lengths that are not nonnegative integers.
      def position(value)
        raise TypeError, "offset and length must be Integers" unless value.is_a?(Integer)
        raise ArgumentError, "offset and length must be nonnegative" if value.negative?
      end

      # Checks that a write payload is a String.
      def string(bytes)
        raise TypeError, "bytes must be a String" unless bytes.is_a?(String)
      end

      # Reads the clock used for writer deadlines.
      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Waits briefly for a writer and rejects an expired deadline.
      def wait_for_writer(deadline)
        remaining = deadline - monotonic_time
        raise BusyError, "writer lock timed out" unless remaining.positive?

        sleep([remaining, 0.005].min)
      end

      # Acquires the process-local writer mutex before its deadline.
      def lock_writer(deadline)
        wait_for_writer(deadline) until @writer_mutex.try_lock
      end

      # Releases the process-local writer mutex.
      def unlock_writer
        @writer_mutex.unlock
      end
    end
    private_constant :Store
  end
end
