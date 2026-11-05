# frozen_string_literal: true

require "tempfile"

module XitDB
  module Streams
    # Restricts stream access to the lifetime of its owning block.
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
        limit = (1 << ((0.size * 8) - 1)) - 1
        raise RangeError, "integer too big to convert into long" unless result.between?(-limit - 1, limit)

        result
      end
    end

    # Reads a captured byte value with bounded storage reads.
    class Reader < Handle
      def initialize(context, slot)
        super(context)
        unless %i[bytes short_bytes].include?(slot.tag) && !slot.full
          raise InvalidValueError, "stream requires untagged bytes"
        end

        @source = Core::Bytes.open(context.database.core, slot, bound: context.read_bound)
        @size = @source.size
        @pos = 0
      end

      def read(length = nil, output = nil)
        check!
        @context.read do
          check!
          count = length.nil? ? [@size - @pos, 0].max : integer(length)
          raise ArgumentError, "negative length" if count.negative?

          buffer = if output.nil?
                     +"".b
                   else
                     String.try_convert(output) || raise(TypeError, "expected a String buffer")
                   end
          buffer.replace("".b)
          return nil if !length.nil? && count.positive? && @pos >= @size

          remaining = count.clamp(0, [@size - @pos, 0].max)
          while remaining.positive?
            size = [remaining, Core::Bytes::CHUNK_SIZE].min
            buffer << @source.read(@pos, size)
            @pos += size
            remaining -= size
          end
          buffer
        end
      end

      def readpartial(length, output = nil)
        check!
        read(integer(length), output) || raise(EOFError, "end of byte stream")
      end

      def seek(offset, whence = IO::SEEK_SET)
        check!
        offset = integer(offset)
        whence = case whence
                 when :SET then IO::SEEK_SET
                 when :CUR then IO::SEEK_CUR
                 when :END then IO::SEEK_END
                 else whence
                 end
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

    # Spools bytes before the enclosing assignment is published.
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
          chunk = bytes.byteslice(position, Core::Bytes::CHUNK_SIZE) || raise(EOFError, "byte source ended")
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
