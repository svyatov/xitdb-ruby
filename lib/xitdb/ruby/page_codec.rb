# frozen_string_literal: true

require_relative "../input_guard"
require_relative "input"
require_relative "page_encoder"
require_relative "page_decoder"

module XitDB
  module Ruby
    # Encodes bounded flat rows with Ruby's byte and numeric operations.
    # @api private
    module PageCodec
      PAGE_LIMIT = 65_536
      ROW_LIMIT = 1024
      FIELD_LIMIT = 16

      def self.encode_page(rows)
        PageEncoder.new.encode(rows)
      end

      # Rows must contain fresh built-in values decoded from stored slots.
      def self.encode_stored_page(rows)
        PageEncoder.new(stored: true).encode(rows)
      end

      def self.decode_page(bytes, expected = nil)
        PageDecoder.new(bytes, expected).page
      end

      def self.decode_row(bytes, index, expected = nil)
        raise TypeError, "row index must be an Integer" unless Object.instance_method(:is_a?).bind_call(index, Integer)
        raise IndexError, "row outside Ruby page" unless index.between?(0, (1 << 62) - 1)

        PageDecoder.new(bytes, expected).row(index)
      end
    end
  end
end
