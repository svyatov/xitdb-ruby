# frozen_string_literal: true

module XitDB
  module Core
    class FileStore
      include Store

      WRITERS = {}
      WRITERS_MUTEX = Mutex.new
      private_constant :WRITERS, :WRITERS_MUTEX

      def self.open(path, readonly: false, buffer_limit: 2 * 1024 * 1024, create: true, exclusive: false)
        raise TypeError, "buffer_limit must be an Integer" unless buffer_limit.is_a?(Integer)
        raise ArgumentError, "buffer_limit must be positive" unless buffer_limit.positive?
        raise ArgumentError, "exclusive opening requires writable creation" if exclusive && (readonly || !create)

        flags = readonly ? File::RDONLY : File::RDWR
        flags |= File::CREAT if create && !readonly
        flags |= File::EXCL if exclusive
        file = File.open(path, flags, 0o666)
        begin
          new(file, readonly, buffer_limit)
        rescue Exception
          file.close
          raise
        end
      end

      def initialize(file, readonly, buffer_limit)
        @file = file.binmode
        @readonly = readonly
        @buffer_limit = buffer_limit
        @pending = "".b
        @pending_offset = 0
        stat = @file.stat
        @identity = [Process.pid, stat.dev, stat.ino]
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
          disk_count = [count, [@file.stat.size - offset, 0].max].min
          result << read_file(offset, disk_count)
          result << "\0".b * (count - disk_count)
          offset += count
        end
        if offset < finish && offset < @pending_offset + @pending.bytesize
          count = [finish - offset, @pending_offset + @pending.bytesize - offset].min
          result << @pending.byteslice(offset - @pending_offset, count)
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

        unless @pending.empty? || (offset >= @pending_offset && offset <= @pending_offset + @pending.bytesize &&
               offset + bytes.bytesize <= @pending_offset + @buffer_limit)
          flush_bytes
        end
        @pending_offset = offset if @pending.empty?
        @pending[offset - @pending_offset, bytes.bytesize] = bytes
      end

      def write_file(offset, bytes)
        written = 0
        while written < bytes.bytesize
          count = retry_interrupted { @file.pwrite(bytes.byteslice(written..), offset + written) }
          raise IOError, "file write made no progress" unless count.positive?

          written += count
        end
      end

      def truncate_bytes(length)
        retry_interrupted { @file.truncate(length) }
        if length <= @pending_offset
          @pending.clear
        elsif length < @pending_offset + @pending.bytesize
          @pending = @pending.byteslice(0, length - @pending_offset)
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
        super
        acquired = false
        begin
          until retry_interrupted { @file.flock(File::LOCK_EX | File::LOCK_NB) }
            wait_for_writer(deadline)
          end
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
