# frozen_string_literal: true

module XitDB
  module Verification
    # A cursor over the physically checked bytes of one inline or external slot.
    class Payload
      attr_reader :start, :size, :position, :tag

      def initialize(scan, slot, offset)
        @scan = scan
        @position = 0
        if slot.tag == :short_bytes
          raw = [slot.value].pack("Q>")
          @tag = Core::Format.slice(raw, 6, 2) if slot.full?
          data = Core::Format.slice(raw, 0, slot.full? ? 6 : 8)
          @size = data.index("\0") || data.bytesize
          @inline = data
          @start = offset + 1
        else
          @size = Core::Format.unsigned(scan.read(slot.value, 8))
          @start = slot.value + 8
          @tag = scan.read(@start + @size, 2) if slot.full?
        end
      end

      def remaining
        size - position
      end

      def length
        value = 0
        (0..63).step(7) do |shift|
          byte = take(1).getbyte(0) || raise(InvalidValueError, "truncated length")
          raise InvalidValueError, "length exceeds database width" if shift == 63 && byte > 1

          value |= (byte & 127) << shift
          next if byte >= 128

          raise InvalidValueError, "nonminimal length" if byte.zero? && shift.positive?
          raise InvalidValueError, "truncated field" if value > remaining

          return value
        end
        raise InvalidValueError, "length exceeds database width"
      end

      def take(length)
        data = +"".b
        chunks(length) { |chunk| data << chunk }
        data
      end

      def chunks(length)
        raise InvalidValueError, "truncated field" if length > remaining

        while length.positive?
          width = [length, Scan::CHUNK_SIZE].min
          inline = @inline
          chunk = inline ? Core::Format.slice(inline, @position, width) : @scan.read(start + @position, width)
          @position += width
          length -= width
          yield chunk
        end
      end
    end
  end
end
