# frozen_string_literal: true

module XitDB
  module Core
    # A synchronized file store with bounded write buffering.
    class FileStore
      include Store

      attr_reader :storage_identity

      WRITERS = {} # rubocop:disable Style/MutableConstant -- Writer registry updates are protected by WRITERS_MUTEX.
      WRITERS_MUTEX = Mutex.new
      private_constant :WRITERS, :WRITERS_MUTEX

      def self.open(path, readonly: false, buffer_limit: 2 * 1024 * 1024, create: true, exclusive: false)
        raise TypeError, "buffer_limit must be an Integer" unless buffer_limit.is_a?(Integer)
        raise ArgumentError, "buffer_limit must be positive" unless buffer_limit.positive?
        raise ArgumentError, "exclusive opening requires writable creation" if exclusive && (readonly || !create)

        file = open_file(path, readonly, create, exclusive)
        begin
          directory = File.dirname(File.expand_path(path)) unless readonly
          new(file, readonly, buffer_limit, sync_directory: directory)
        rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
          file.close
          raise
        end
      end

      def self.open_file(path, readonly, create, exclusive)
        flags = readonly ? File::RDONLY : File::RDWR
        return File.open(path, flags) unless create && !readonly

        begin
          File.open(path, flags | File::CREAT | File::EXCL, 0o666)
        rescue Errno::EEXIST
          raise if exclusive

          File.open(path, flags)
        end
      end
      private_class_method :open_file

      def initialize(file, readonly, buffer_limit, sync_directory: nil)
        @file = file.binmode
        @sync_directory = sync_directory
        @readonly = readonly
        @buffer_limit = buffer_limit
        @pending = "".b
        @pending_offset = 0
        stat = @file.stat
        @identity = [Process.pid, stat.dev, stat.ino].freeze
        @storage_identity = @identity
        writer = WRITERS_MUTEX.synchronize do
          entry = WRITERS[@identity] ||= [Mutex.new, 0]
          entry[1] += 1
          entry[0]
        end
        initialize_state(writer)
      end

      def readonly?
        @readonly
      end

      private

      def store_length
        disk_length = @file.stat.size
        @pending.empty? ? disk_length : [disk_length, @pending_offset + @pending.bytesize].max
      end

      def read_bytes(offset, length)
        return read_file(offset, length) if @pending.empty?

        result = "".b
        finish = offset + length
        if offset < @pending_offset
          count = [finish, @pending_offset].min - offset
          disk_count = (@file.stat.size - offset).clamp(0, count)
          result << read_file(offset, disk_count)
          result << ("\0".b * (count - disk_count))
          offset += count
        end
        if offset < finish && offset < @pending_offset + @pending.bytesize
          count = [finish - offset, @pending_offset + @pending.bytesize - offset].min
          result << Format.slice(@pending, offset - @pending_offset, count)
          offset += count
        end
        result << read_file(offset, finish - offset) if offset < finish
        result
      end

      def read_file(offset, length)
        result = "".b
        while result.bytesize < length
          bytes = retry_interrupted { @file.pread(length - result.bytesize, offset + result.bytesize) }
          raise EOFError, "read exceeds file length" if bytes.empty?

          result << bytes
        end
        result
      end

      def write_bytes(offset, bytes)
        if bytes.bytesize > @buffer_limit
          flush_bytes
          write_file(offset, bytes)
          return
        end

        unless @pending.empty? || (offset.between?(@pending_offset, @pending_offset + @pending.bytesize) &&
               offset + bytes.bytesize <= @pending_offset + @buffer_limit)
          flush_bytes
        end
        @pending_offset = offset if @pending.empty?
        @pending[offset - @pending_offset, bytes.bytesize] = bytes
      end

      def write_file(offset, bytes)
        written = 0
        while written < bytes.bytesize
          count = retry_interrupted { @file.pwrite(Format.slice(bytes, written..), offset + written) }
          raise IOError, "file write made no progress" unless count.positive?

          written += count
        end
      end

      def truncate_bytes(length)
        retry_interrupted { @file.truncate(length) }
        if length <= @pending_offset
          @pending.clear
        elsif length < @pending_offset + @pending.bytesize
          @pending = Format.slice(@pending, 0, length - @pending_offset)
        end
      end

      def flush_bytes
        return if @pending.empty?

        write_file(@pending_offset, @pending)
        @pending.clear
        nil
      end

      def sync_bytes
        retry_interrupted { @file.fsync }
        sync_directory = @sync_directory
        if sync_directory
          File.open(sync_directory, File::RDONLY) do |directory|
            retry_interrupted { directory.fsync }
          end
          @sync_directory = nil
        end
        nil
      end

      def close_bytes
        @file.close
        WRITERS_MUTEX.synchronize do
          entry = WRITERS.fetch(@identity)
          entry[1] -= 1
          WRITERS.delete(@identity) if entry[1].zero?
        end
      end

      def lock_writer(deadline)
        raise TransactionStateError, "writer lock for this file is already held by this thread" if @writer_mutex.owned?

        super
        acquired = false
        begin
          wait_for_writer(deadline) until retry_interrupted { @file.flock(File::LOCK_EX | File::LOCK_NB) }
          acquired = true
        ensure
          @writer_mutex.unlock unless acquired
        end
      end

      def unlock_writer
        retry_interrupted { @file.flock(File::LOCK_UN) }
      ensure
        super
      end

      def retry_interrupted
        yield
      rescue Errno::EINTR
        retry
      end
    end
  end
end
