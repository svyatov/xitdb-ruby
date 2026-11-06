# frozen_string_literal: true

module XitDB
  module Core
    # An immutable copy of binary payload bytes and an optional application format tag.
    class ByteValue
      # @!attribute [r] bytes
      #   Frozen binary payload.
      #   @return [String]
      # @!attribute [r] format_tag
      #   Optional frozen two-byte application format identifier.
      #   @return [String, nil]
      attr_reader :bytes, :format_tag

      # Copies bytes and an optional two-byte tag into a frozen value.
      # @param bytes [String] binary input bytes
      # @param format_tag [String, nil] optional two-byte application format identifier
      # @return [ByteValue]
      # @raise [TypeError] if bytes is not a String
      # @raise [ArgumentError] if format_tag is neither nil nor a two-byte String
      def initialize(bytes, format_tag: nil)
        raise TypeError, "bytes must be a String" unless bytes.is_a?(String)
        unless format_tag.nil? || (format_tag.is_a?(String) && format_tag.bytesize == 2)
          raise ArgumentError, "format_tag must contain two bytes"
        end

        @bytes = bytes.b.freeze
        @format_tag = format_tag&.b&.freeze
        freeze
      end
    end
  end
end
