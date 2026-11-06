# frozen_string_literal: true

module XitDB
  module Core
    # Binary decoding checks shared by the storage implementation.
    #
    # A byte offset counts from the start of the file. All stored integers use explicit binary widths.
    # @api private
    module Format
      # Largest integer that fits in an unsigned 64-bit field.
      UINT64_MAX = (1 << 64) - 1

      # Checks that an integer is inside the allowed range.
      # @param value [Object] value to validate as an Integer
      # @param range [Range<Integer>] allowed integer values
      # @return [Integer]
      # @raise [TypeError] if value is not an Integer
      # @raise [RangeError] if value is outside range
      def self.integer(value, range)
        raise TypeError, "expected Integer, got #{value.class}" unless value.is_a?(Integer)
        raise RangeError, "integer outside #{range}" unless range.cover?(value)

        value
      end

      # Checks that a byte string has exactly the required width.
      # @param bytes [String] binary input bytes
      # @param width [Integer] required byte count
      # @return [void]
      # @raise [TypeError] if bytes is not a String
      # @raise [CorruptionError] if the width differs
      def self.width(bytes, width)
        raise TypeError, "expected String, got #{bytes.class}" unless bytes.is_a?(String)
        raise CorruptionError, "expected #{width} bytes, got #{bytes.bytesize}" unless bytes.bytesize == width
      end

      # Reads a byte range and rejects a missing slice.
      # @param bytes [String] binary input to slice
      # @param offset [Integer, Range] byte index or range within bytes
      # @param length [Integer, nil] byte count; nil selects one byte for an integer offset
      # @return [String]
      # @raise [CorruptionError] if the slice starts outside the payload
      def self.slice(bytes, offset, length = nil)
        result = if offset.is_a?(Range)
                   bytes.byteslice(offset)
                 else
                   bytes.byteslice(offset, length || 1)
                 end
        raise CorruptionError, "byte slice exceeds payload" unless result

        result
      end

      # Decodes an unsigned 64-bit integer in big-endian order.
      # @param bytes [String] binary input bytes
      # @return [Integer]
      def self.unsigned(bytes)
        value = bytes.unpack1("Q>")
        raise CorruptionError, "invalid unsigned integer" unless value.is_a?(Integer)

        value
      end

      # Decodes packed integers and rejects incomplete values.
      # @param bytes [String] binary input bytes
      # @param format [String] Ruby unpack format for the packed integers
      # @return [Array<Integer>]
      def self.integers(bytes, format)
        bytes.unpack(format).map do |value|
          raise CorruptionError, "invalid integer payload" unless value.is_a?(Integer)

          value
        end
      end

      # Decodes the first two integers in a packed record.
      # @param bytes [String] binary input bytes
      # @param format [String] Ruby unpack format for the packed integers
      # @return [Array(Integer, Integer)]
      def self.pair(bytes, format)
        values = integers(bytes, format)
        [values.fetch(0), values.fetch(1)]
      end
    end
  end
end

require_relative "header"
require_relative "slot"
