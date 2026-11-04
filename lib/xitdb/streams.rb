# frozen_string_literal: true

require "tempfile"

module XitDB
  module Streams
    class Handle
      def initialize(context)
        @context = context
        @active = true
      end

      def expire!
        @active = false
      end

      private

      def check!
        raise ExpiredViewError, "byte stream block has ended" unless @active

        @context.check!
      end

      def integer(value)
        result = Integer.try_convert(value) || raise(TypeError, "expected an Integer")
        limit = (1 << (0.size * 8 - 1)) - 1
        raise RangeError, "integer too big to convert into long" unless result.between?(-limit - 1, limit)

        result
      end
    end

    class Reader < Handle
      def initialize(context, slot)
        super(context)
        @bound = context.read_bound
        @source, @size = Core::Bytes.locate(context.database.core, slot, bound: @bound)
        @pos = 0
      end

      def read(length = nil, output = nil)
        check!
        @context.read do
          check!
          count = length.nil? ? [@size - @pos, 0].max : integer(length)
          raise ArgumentError, "negative length" if count.negative?

          output = output.nil? ? +"".b : String.try_convert(output) || raise(TypeError, "expected a String buffer")
          output.replace("".b)
          return nil if !length.nil? && count.positive? && @pos >= @size

          remaining = [count, [@size - @pos, 0].max].min
          while remaining.positive?
            size = [remaining, Core::Bytes::CHUNK_SIZE].min
            chunk = if @source.is_a?(String)
              @source.byteslice(@pos, size)
            else
              @context.database.core.read_at(@source + @pos, size, bound: @bound)
            end
            output << chunk
            @pos += size
            remaining -= size
          end
          output
        end
      end

      def readpartial(length, output = nil)
        check!
        read(integer(length), output) || raise(EOFError, "end of byte stream")
      end

      def seek(offset, whence = IO::SEEK_SET)
        check!
        offset = integer(offset)
        whence = {SET: IO::SEEK_SET, CUR: IO::SEEK_CUR, END: IO::SEEK_END}.fetch(whence, whence)
        base = case integer(whence)
        when IO::SEEK_SET then 0
        when IO::SEEK_CUR then @pos
        when IO::SEEK_END then @size
        else raise Errno::EINVAL, "invalid seek origin"
        end
        position = base + offset
        raise Errno::EINVAL, "negative seek position" if position.negative?

        @pos = integer(position)
        0
      end

      def rewind
        seek(0)
      end

      def pos
        check!
        @pos
      end

      def size
        check!
        @size
      end

      def eof?
        check!
        @pos >= @size
      end
    end

    class Writer < Handle
      def initialize(context, spool)
        super(context)
        @spool = spool
      end

      def write(value)
        check!
        bytes = value.to_s
        raise TypeError, "to_s must return a String" unless bytes.is_a?(String)

        position = 0
        while position < bytes.bytesize
          check!
          chunk = bytes.byteslice(position, Core::Bytes::CHUNK_SIZE)
          position += @spool.write(chunk)
        end
        position
      end

      def pos
        check!
        @spool.pos
      end
    end
  end
end
