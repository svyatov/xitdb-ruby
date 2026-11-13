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
        @directory = 0
        @payload = 0
      end

      def encode(rows)
        bytes = super
        return unless bytes

        bytes[@directory, @offsets.size * 2] = @offsets.pack("S<*")
        bytes + Digest::SHA256.digest(bytes)
      end

      private

      # rubocop:disable-next Naming/PredicateMethod -- Writes the schema before reserving row offsets.
      def write_schema(first, count)
        return false unless super

        size = (count + 1) * 2
        return false if size > PageCodec::PAGE_LIMIT - 32 - @bytes.bytesize

        @directory = @bytes.bytesize
        @bytes << ("\x00".b * size)
        @payload = @bytes.bytesize
        true
      end

      # rubocop:disable-next Naming/PredicateMethod -- Appends row offsets on success.
      def encode_row(row)
        return false unless super

        @offsets << (@bytes.bytesize - @payload)
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
