# frozen_string_literal: true

module XitDB
  module Profiles
    class Portable
      attr_reader :hasher

      def initialize(hasher: Core::Hasher.sha1)
        raise TypeError, "hasher must be a Core::Hasher" unless hasher.is_a?(Core::Hasher)

        @hasher = hasher
        freeze
      end

      def encode_scalar(value, core:)
        case value
        when nil then Core::Slot.null
        when UInt then Core::Slot.uint(value.value)
        when Integer
          value > (1 << 63) - 1 ? Core::Slot.uint(value) : Core::Slot.int(value)
        when Float then Core::Slot.float(value)
        when String then core.bytes(value)
        when Core::ByteValue then core.bytes(value.bytes, format_tag: value.format_tag)
        else
          raise UnsupportedValueError, "unsupported portable scalar: #{value.class}"
        end
      end

      def decode_scalar(slot, core:, bound: nil, immutable: true)
        case slot.tag
        when :none then nil
        when :uint then slot.value
        when :int then slot.value >= (1 << 63) ? slot.value - (1 << 64) : slot.value
        when :float then [slot.value].pack("Q>").unpack1("G")
        when :bytes, :short_bytes
          value = core.read_bytes(slot, bound: bound)
          return value if value.format_tag

          bytes = value.bytes.dup.force_encoding(Encoding::UTF_8)
          bytes.force_encoding(Encoding::BINARY) unless bytes.valid_encoding?
          immutable ? bytes.freeze : bytes
        else
          raise UnsupportedValueError, "unsupported portable scalar tag: #{slot.tag}"
        end
      end

      def key_bytes(value)
        raise UnsupportedValueError, "portable keys must be strings" unless value.is_a?(String)

        value.b.freeze
      end
    end
  end
end
