# frozen_string_literal: true

module XitDB
  module Ruby
    # Preserves a complete scalar payload when its application codec is unavailable.
    # The bytes include the Ruby payload version, type, codec identifier, and serialized data.
    # Writing this object stores those bytes unchanged, which permits later decoding with the matching codec.
    class EncodedValue
      attr_reader :codec_id, :format_tag, :bytes

      # @!attribute [r] codec_id
      #   Frozen identifier for the missing application codec.
      #
      #   @return [String] frozen identifier for the missing application codec
      # @!attribute [r] format_tag
      #   Frozen storage format label.
      #
      #   @return [String, nil] frozen storage format label
      # @!attribute [r] bytes
      #   Frozen complete payload, including version and codec fields.
      #
      #   @return [String] frozen complete payload, including version and codec fields

      # Copies and freezes the stored bytes and codec identifier.
      #
      # @param codec_id [String] identifier of the missing application codec
      # @param bytes [String] complete encoded scalar payload
      # @param format_tag [String] storage format label, normally "rb"
      def initialize(codec_id:, bytes:, format_tag: "rb")
        value = Core::ByteValue.new(bytes, format_tag: format_tag)
        @codec_id = codec_id.dup.freeze
        @format_tag = value.format_tag
        @bytes = value.bytes
        freeze
      end
    end
  end
end
