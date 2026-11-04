# frozen_string_literal: true

require "date"
require "bigdecimal"
require_relative "../core"
require_relative "../input_guard"
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
      TYPES = [NilClass, FalseClass, TrueClass, Integer, Float, String, Symbol, Time, Date, DateTime,
               BigDecimal, Rational, EncodedValue, Core::ByteValue].freeze
      private_constant :TYPES

      def self.encode(value, core:, registry: nil)
        InputGuard.check!(value)
        if (codec = registry&.for_value(value))
          payload = "\x01\x0a".b + Wire.t(codec.id) + Wire.b(codec.dump(value))
          return core.bytes(payload, format_tag: "rb")
        end
        unless builtin_type?(Object.instance_method(:class).bind_call(value))
          raise UnsupportedValueError, "unsupported Ruby scalar class"
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
        when Time
          offset = value.utc_offset
          unless offset == offset.to_i
            raise UnsupportedValueError, "Ruby profile Time offsets require whole seconds"
          end

          "\x05".b + Wire.q(value.to_r) + Wire.z(offset.to_i) + (value.utc? ? "\x01".b : "\x00".b)
        when DateTime
          "\x07".b + Wire.q(value.ajd) + Wire.q(value.offset) + Wire.f64(value.start)
        when Date then "\x06".b + Wire.z(value.jd) + Wire.f64(value.start)
        when BigDecimal then "\x08".b + decimal_bytes(value)
        when Rational then "\x09".b + Wire.q(value)
        when EncodedValue, Core::ByteValue
          return core.bytes(value.bytes, format_tag: value.format_tag)
        else
          raise UnsupportedValueError, "unsupported Ruby scalar: #{value.class}"
        end
        core.bytes("\x01".b + payload, format_tag: "rb")
      end

      def self.builtin_type?(type)
        TYPES.include?(type)
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
          when "rb" then decode_payload(stored.bytes, registry: registry)
          else stored
          end
        else
          raise InvalidValueError, "expected Ruby scalar, got slot tag #{slot.tag}"
        end
        immutable ? Object.instance_method(:freeze).bind_call(value) : value
      end

      def self.decode_payload(bytes, registry: nil)
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
        when 5 then read_time(reader)
        when 6 then Date.jd(reader.z, read_start(reader))
        when 7 then read_datetime(reader)
        when 8 then read_decimal(reader)
        when 9 then reader.q
        when 10
          codec_id = reader.t
          payload = reader.b
          reader.finish!
          codec = registry&.for_id(codec_id)
          return codec ? codec.load(payload) : EncodedValue.new(codec_id: codec_id, bytes: bytes)
        else
          raise UnsupportedEncodingError, "unsupported Ruby builtin type #{type}"
        end
        reader.finish!
        value
      rescue ArgumentError, RangeError => error
        raise InvalidValueError, error.message
      end

      def self.decimal_bytes(value)
        return "\x03".b if value.nan?
        return value.positive? ? "\x01".b : "\x02".b if value.infinite?

        sign, digits, base, exponent = value.split
        raise InvalidValueError, "decimal base must be ten" unless base == 10

        "\x00".b + (sign.negative? ? "\x01".b : "\x00".b) + Wire.t(digits) + Wire.z(exponent)
      end

      def self.read_time(reader)
        instant = reader.q
        offset = reader.z
        utc = reader.byte
        unless utc <= 1 && offset.abs < 86_400 && (utc.zero? || offset.zero?)
          raise InvalidValueError, "invalid Time offset or UTC flag"
        end

        time = Time.at(instant)
        utc == 1 ? time.utc : time.getlocal(offset)
      end

      def self.read_start(reader)
        start = reader.f64
        unless start.infinite? || (2_298_874..2_426_355).cover?(start)
          raise InvalidValueError, "invalid calendar start"
        end

        start
      end

      def self.read_datetime(reader)
        instant = reader.q
        offset = reader.q
        start = read_start(reader)
        unless offset.abs <= 1 && (offset * 86_400).denominator == 1
          raise InvalidValueError, "invalid DateTime offset"
        end

        day, fraction = (instant + Rational(1, 2) + offset).divmod(1)
        DateTime.jd(day, 0, 0, 0, offset, start) + fraction
      end

      def self.read_decimal(reader)
        kind = reader.byte
        case kind
        when 0
          sign = reader.byte
          digits = reader.t
          exponent = reader.z
          unless sign <= 1 && /\A(?:0|[1-9](?:[0-9]*[1-9])?)\z/.match?(digits) && (digits != "0" || exponent.zero?)
            raise InvalidValueError, "invalid finite decimal fields"
          end

          text = "#{sign == 1 ? '-' : ''}0.#{digits}e#{exponent}"
        when 1 then text = "Infinity"
        when 2 then text = "-Infinity"
        when 3 then text = "NaN"
        else raise InvalidValueError, "invalid decimal kind"
        end
        value = BigDecimal.save_exception_mode do
          BigDecimal.mode(BigDecimal::EXCEPTION_ALL, false)
          BigDecimal(text)
        end
        if kind.zero? && value.split != [sign == 1 ? -1 : 1, digits, 10, exponent]
          raise InvalidValueError, "decimal is outside the supported exponent range"
        end

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
      private_class_method :decode_payload, :read_string, :decimal_bytes, :read_time, :read_start,
        :read_datetime, :read_decimal
    end
  end
end
