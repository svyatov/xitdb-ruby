# frozen_string_literal: true

require_relative "../core"
require_relative "wire"

module XitDB
  module Ruby
    class EncodedValue
      attr_reader :codec_id, :format_tag, :bytes

      def initialize(codec_id:, bytes:, format_tag: "rb")
        value = Core::ByteValue.new(bytes, format_tag: format_tag)
        @codec_id = codec_id.dup.freeze
        @format_tag = value.format_tag
        @bytes = value.bytes
        freeze
      end
    end

    module Scalars
      def self.encode(value, core:, registry: nil)
        unless value.singleton_methods.empty?
          raise UnsupportedValueError, "singleton scalar behavior is unsupported"
        end

        payload = case value
        when nil then return Core::Slot.null
        when Integer
          return Core::Slot.int(value) if (-(1 << 63)...(1 << 63)).cover?(value)
          return Core::Slot.uint(value) if (0...(1 << 64)).cover?(value)

          "\x04".b + Wire.z(value)
        when Float then return Core::Slot.float(value)
        when String then "\x01".b + Wire.t(value.encoding.name) + Wire.b(value)
        when Symbol
          name = value.to_s
          "\x02".b + Wire.t(name.encoding.name) + Wire.b(name)
        when false then "\x03\x00".b
        when true then "\x03\x01".b
        when EncodedValue, Core::ByteValue
          return core.bytes(value.bytes, format_tag: value.format_tag)
        else
          raise UnsupportedValueError, "unsupported Ruby scalar: #{value.class}"
        end
        core.bytes("\x01".b + payload, format_tag: "rb")
      end

      def self.decode(slot, core:, bound: nil, registry: nil, immutable: true)
        value = case slot.tag
        when :none then nil
        when :int then slot.value >= (1 << 63) ? slot.value - (1 << 64) : slot.value
        when :uint then slot.value
        when :float then [slot.value].pack("Q>").unpack1("G")
        when :bytes, :short_bytes
          stored = core.read_bytes(slot, bound: bound)
          case stored.format_tag
          when nil then stored.bytes.dup
          when "rb" then decode_payload(stored.bytes)
          else stored
          end
        else
          raise InvalidValueError, "expected Ruby scalar, got slot tag #{slot.tag}"
        end
        immutable ? value.freeze : value
      end

      def self.decode_payload(bytes)
        reader = Wire::Reader.new(bytes)
        version = reader.byte
        raise UnsupportedEncodingError, "unsupported Ruby payload version #{version}" unless version == 1

        type = reader.byte
        value = case type
        when 1 then read_string(reader)
        when 2
          name = read_string(reader)
          raise InvalidValueError, "invalid Symbol bytes" unless name.valid_encoding?

          begin
            name.to_sym
          rescue EncodingError, ArgumentError => error
            raise InvalidValueError, error.message
          end
        when 3
          flag = reader.byte
          raise InvalidValueError, "invalid Boolean flag" unless flag <= 1

          flag == 1
        when 4 then reader.z
        when 10
          codec_id = reader.t
          reader.b
          EncodedValue.new(codec_id: codec_id, bytes: bytes)
        else
          raise UnsupportedEncodingError, "unsupported Ruby builtin type #{type}"
        end
        reader.finish!
        value
      end

      def self.read_string(reader)
        name = reader.t
        bytes = reader.b
        begin
          encoding = Encoding.find(name)
        rescue ArgumentError => error
          raise UnsupportedEncodingError, error.message
        end
        bytes.force_encoding(encoding)
      end
      private_class_method :decode_payload, :read_string
    end
  end
end
