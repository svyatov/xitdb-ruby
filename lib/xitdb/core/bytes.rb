# frozen_string_literal: true

module XitDB
  module Core
    class ByteValue
      attr_reader :bytes, :format_tag

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
