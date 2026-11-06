# frozen_string_literal: true

module XitDB
  module Streams
    # Reads a captured byte value with bounded storage reads.
    class Reader < Handle
      # Capture an untagged byte value and start reading at position zero.
      # @api private
      # @param context [Context]
      # @param slot [Core::Slot]
      # @raise [InvalidValueError] if the slot is not untagged bytes
      def initialize(context, slot)
        super(context)
        unless %i[bytes short_bytes].include?(slot.tag) && !slot.full
          raise InvalidValueError, "stream requires untagged bytes"
        end

        @source = Core::Bytes.open(context.database.core, slot, bound: context.read_bound)
        @size = @source.size
        @pos = 0
      end

      # Read bytes and advance the position, optionally reusing a String buffer.
      #
      # Without length, read all remaining bytes and return an empty String at EOF.
      # With positive length, return nil at EOF. A zero length returns an empty String.
      # @param length [Integer, nil] maximum bytes; nil reads the remainder
      # @param output [String, nil] buffer replaced with binary data
      # @return [String, nil]
      # @raise [ArgumentError] if length is negative
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

      # Read up to length bytes, raising at the end of the stream.
      # @param length [Integer] maximum bytes
      # @param output [String, nil] optional reusable buffer
      # @return [String]
      # @raise [EOFError] if a positive-length read starts at EOF
      def readpartial(length, output = nil)
        check!
        read(integer(length), output) || raise(EOFError, "end of byte stream")
      end

      # Move the position relative to the start, current position, or end.
      # @param offset [Integer] signed byte displacement
      # @param whence [Integer, Symbol] IO seek constant or :SET, :CUR, :END
      # @return [Integer] zero
      # @raise [Errno::EINVAL] if the origin is invalid or the resulting position is negative
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

      # Move back to the first byte.
      # @return [Integer] zero
      def rewind
        seek(0)
      end

      # Read the current byte position within the stream.
      # @return [Integer]
      def pos
        check!
        @pos
      end

      # Read the captured value's total byte length.
      # @return [Integer]
      def size
        check!
        @size
      end

      # Report whether the position is at or beyond the captured end.
      # @return [Boolean]
      def eof?
        check!
        @pos >= @size
      end
    end
  end
end
