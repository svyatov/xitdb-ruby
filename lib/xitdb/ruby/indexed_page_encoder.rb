# frozen_string_literal: true

require "digest"

module XitDB
  module Ruby
    # Adds bounded row offsets and whole-page integrity to compact cells.
    # @api private
    class IndexedPageEncoder < PageEncoder
      def initialize(stored: false)
        super
        @bytes[0, 4] = "XR01"
        @offsets = [0]
        @payload = 0
        @max_width = 0
      end

      def encode(rows)
        bytes = super
        return unless bytes

        padding = (@max_width * (@offsets.size - 1)) - @offsets.fetch(-1)
        if padding.zero?
          bytes[0, 4] = "XF01"
        elsif padding < @offsets.size * 2
          return if bytes.bytesize + padding + 32 > PageCodec::PAGE_LIMIT

          bytes = padded_rows(bytes)
        else
          return if bytes.bytesize + (@offsets.size * 2) + 32 > PageCodec::PAGE_LIMIT

          bytes.insert(@payload, @offsets.pack("S<*"))
        end
        bytes + Digest::SHA256.digest(bytes)
      end

      private

      def padded_rows(bytes)
        output = bytes.byteslice(0, @payload) || raise(InvalidValueError, "missing page schema")
        output[0, 4] = "XA01"
        count = @offsets.size - 1
        output << ("\x00" * (count * @max_width))
        count.times do |index|
          left = @offsets.fetch(index)
          width = @offsets.fetch(index + 1) - left
          output.bytesplice(@payload + (index * @max_width), width, bytes, @payload + left, width)
        end
        output
      end

      # rubocop:disable-next Naming/PredicateMethod -- Records the start of the row payload.
      def write_schema(first, count)
        return false unless super

        @payload = @bytes.bytesize
        true
      end

      # rubocop:disable-next Naming/PredicateMethod -- Appends row offsets on success.
      def encode_row(row)
        return false unless super

        offset = @bytes.bytesize - @payload
        @max_width = [@max_width, offset - @offsets.fetch(-1)].max
        @offsets << offset
        true
      end

      # rubocop:disable-next Naming/PredicateMethod -- Appends bytes on success.
      def append(bytes)
        return false unless bytes && bytes.bytesize <= PageCodec::PAGE_LIMIT - 32 - @bytes.bytesize

        @bytes << bytes
        true
      end
    end
  end
end
