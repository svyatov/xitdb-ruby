# frozen_string_literal: true

require_relative "input"
require_relative "page_encoder"
require_relative "page_decoder"
require_relative "indexed_page_encoder"
require_relative "indexed_page_decoder"

module XitDB
  module Ruby
    # Encodes bounded flat rows with Ruby's byte and numeric operations.
    # @api private
    module PageCodec
      PAGE_LIMIT = 65_536
      ROW_LIMIT = 1024
      FIELD_LIMIT = 16

      def self.encode_page(rows)
        IndexedPageEncoder.new.encode(rows) || PageEncoder.new.encode(rows)
      end

      # Rows must contain fresh built-in values decoded from stored slots.
      def self.encode_stored_page(rows)
        IndexedPageEncoder.new(stored: true).encode(rows) || PageEncoder.new(stored: true).encode(rows)
      end

      def self.decode_page(bytes, expected = nil)
        decoder(bytes, expected).page
      end

      def self.decode_row(bytes, index, expected = nil)
        raise TypeError, "row index must be an Integer" unless Object.instance_method(:is_a?).bind_call(index, Integer)
        raise IndexError, "row outside Ruby page" unless index.between?(0, (1 << 62) - 1)

        decoder(bytes, expected).row(index)
      end

      def self.decoder(bytes, expected)
        # @type var prefix: String
        prefix = String.instance_method(:byteslice).bind_call(bytes, 0, 4)
        prefix == "XR01" ? IndexedPageDecoder.new(bytes, expected) : PageDecoder.new(bytes, expected)
      end
      private_class_method :decoder
    end
  end
end
