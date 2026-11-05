# frozen_string_literal: true

require "date"
require "bigdecimal"
require_relative "../core"
require_relative "../input_guard"
require_relative "wire"
require_relative "key_encoding"

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

    # Converts individual Ruby values to slots and reconstructs them from storage.
    # A scalar is one value, such as a String or Time, rather than a map, set, or array.
    # Nil, machine-sized integers, and Float values use native slots.
    # Other Ruby values use versioned bytes tagged "rb", which preserve types and string encodings.
    # Unregistered custom classes are rejected; missing codecs return {EncodedValue} objects.
    module Scalars
      # Exact scalar classes handled without an application codec.
      TYPES = [NilClass, FalseClass, TrueClass, Integer, Float, String, Symbol, Time, Date, DateTime,
               BigDecimal, Rational, EncodedValue, Core::ByteValue].freeze
      private_constant :TYPES

      # Stores one scalar, using a registered codec before checking built-in types.
      #
      # @param value [Object] supported built-in scalar or registered application value
      # @param core [Core::Database] destination storage
      # @param registry [CodecRegistry, nil] custom serializers available for this write
      # @return [Core::Slot] stored value descriptor
      # @raise [UnsupportedValueError] if the exact class or singleton behavior is unsupported
      # @raise [CodecError] if application serialization fails
      def self.encode(value, core:, registry: nil)
        InputGuard.check!(value)
        if (codec = registry&.for_value(value))
          payload = "\x01\x0a".b + Wire.t(codec.id) + Wire.b(codec.dump(value))
          return core.bytes(payload, format_tag: "rb")
        end
        unless builtin_type?(Object.instance_method(:class).bind_call(value))
          raise UnsupportedValueError, "unsupported Ruby scalar class"
        end

        value = checked_builtin(value)
        builtin_slot(value, core)
      end

      # Narrows a validated value to the supported built-in scalar union.
      #
      # @param value [Object] candidate built-in scalar
      # @return [Object] the supported value
      # @raise [UnsupportedValueError] if the value cannot be treated as a built-in scalar
      def self.checked_builtin(value)
        case value
        when Object
          checked_object_builtin(value)
        else
          raise UnsupportedValueError, "unsupported Ruby scalar class"
        end
      end

      # Recognizes extended built-ins before checking basic key-compatible scalars.
      #
      # @param value [Object] candidate built-in scalar
      # @return [Object] the supported value
      # @raise [UnsupportedValueError] if no supported scalar type matches
      def self.checked_object_builtin(value)
        return value if value.is_a?(DateTime)
        return value if value.is_a?(Date)
        return value if value.is_a?(BigDecimal)

        case value
        when Time, Rational, EncodedValue, Core::ByteValue
          value
        else
          KeyEncoding.checked_key(value)
        end
      end

      # Uses a native slot when possible and tagged bytes for other built-ins.
      # Integers outside signed or unsigned 64-bit ranges use an arbitrary-precision payload.
      #
      # @param value [Object] validated built-in scalar
      # @param core [Core::Database] destination storage
      # @return [Core::Slot] native scalar or stored byte descriptor
      def self.builtin_slot(value, core)
        case value
        when nil then Core::Slot.null
        when Integer
          return Core::Slot.int(value) if (-(1 << 63)...(1 << 63)).cover?(value)
          return Core::Slot.uint(value) if (0...(1 << 64)).cover?(value)

          core.bytes("\x01\x04".b + Wire.z(value), format_tag: "rb")
        when Float then Core::Slot.float(value)
        when EncodedValue, Core::ByteValue then core.bytes(value.bytes, format_tag: value.format_tag)
        else core.bytes("\x01".b + builtin_payload(value), format_tag: "rb")
        end
      end

      # Encodes a built-in type marker and its fields, without the version byte.
      #
      # @param value [Object] scalar requiring a tagged payload
      # @return [String] binary type marker and fields
      # @raise [UnsupportedValueError] if the value has no supported payload type
      def self.builtin_payload(value)
        case value
        when String then "\x01".b + Wire.t(value.encoding.name) + Wire.b(value)
        when Symbol
          name = value.to_s
          "\x02".b + Wire.t(name.encoding.name) + Wire.b(name)
        when false then "\x03\x00".b
        when true then "\x03\x01".b
        when Time then time_bytes(value)
        when DateTime then "\x07".b + Wire.q(value.ajd) + Wire.q(value.offset) + Wire.f64(value.start)
        when Date then "\x06".b + Wire.z(value.jd) + Wire.f64(value.start)
        when Rational then "\x09".b + Wire.q(value)
        else decimal_payload(value)
        end
      end

      # Adds the decimal type marker to a BigDecimal field.
      #
      # @param value [BigDecimal] decimal value
      # @return [String] decimal type marker and payload
      # @raise [UnsupportedValueError] if the value is not a BigDecimal
      def self.decimal_payload(value)
        unless value.is_a?(BigDecimal)
          raise UnsupportedValueError, "unsupported Ruby scalar: #{Object.instance_method(:class).bind_call(value)}"
        end

        "\x08".b + decimal_bytes(value)
      end

      # Stores an exact Time instant, its offset, and whether it uses UTC.
      #
      # @param value [Time] time to preserve
      # @return [String] time type marker and fields
      # @raise [UnsupportedValueError] if the UTC offset contains fractional seconds
      def self.time_bytes(value)
        offset = value.utc_offset
        raise UnsupportedValueError, "Ruby profile Time offsets require whole seconds" unless offset == offset.to_i

        "\x05".b + Wire.q(value.to_r) + Wire.z(offset.to_i) + (value.utc? ? "\x01".b : "\x00".b)
      end

      # Checks exact class membership in the built-in scalar list.
      #
      # @param type [Class] class to test
      # @return [Boolean] whether the class is supported without a codec
      def self.builtin_type?(type)
        TYPES.include?(type)
      end

      # Reads one scalar and optionally freezes the returned object.
      # Untagged bytes become binary Strings; foreign format tags remain Core::ByteValue objects.
      #
      # @param slot [Core::Slot] stored scalar descriptor
      # @param core [Core::Database] source storage
      # @param bound [Integer, nil] exclusive read limit, or the core default
      # @param registry [CodecRegistry, nil] available application deserializers
      # @param immutable [Boolean] whether to freeze the decoded object, including a codec result
      # @return [Object] built-in scalar, decoded application object, or EncodedValue
      # @raise [InvalidValueError] if the slot or payload is malformed
      # @raise [UnsupportedEncodingError] if its version, type, or encoding is unsupported
      # @raise [CodecError] if application deserialization fails
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

      # Checks the Ruby payload version, decodes its type, and rejects extra bytes.
      #
      # @param bytes [String] complete Ruby scalar payload
      # @param registry [CodecRegistry, nil] available application deserializers
      # @return [Object] decoded scalar
      # @raise [UnsupportedEncodingError] if the version or type is unsupported
      # @raise [InvalidValueError] if fields are malformed, truncated, or followed by extra bytes
      def self.decode_payload(bytes, registry: nil)
        reader = Wire::Reader.new(bytes)
        version = reader.byte
        raise UnsupportedEncodingError, "unsupported Ruby payload version #{version}" unless version == 1

        value = decode_type(reader, bytes, registry)
        reader.finish!
        value
      rescue ArgumentError, RangeError => e
        raise InvalidValueError, e.message
      end

      # Consumes the type marker and dispatches to the corresponding scalar reader.
      #
      # @param reader [Wire::Reader] reader positioned after the version byte
      # @param bytes [String] complete payload retained for missing codecs
      # @param registry [CodecRegistry, nil] application deserializers
      # @return [Object] decoded scalar
      # @raise [UnsupportedEncodingError] if the type marker is unsupported
      def self.decode_type(reader, bytes, registry)
        type = reader.byte
        case type
        when 1 then read_string(reader)
        when 2 then read_symbol(reader)
        when 3 then read_boolean?(reader)
        when 4 then reader.z
        when 5 then read_time(reader)
        when 6 then Date.jd(reader.z, read_start(reader))
        when 7 then read_datetime(reader)
        when 8 then read_decimal(reader)
        else decode_extended_type(type, reader, bytes, registry)
        end
      end

      # Decodes Rational and codec fields after the primary built-in type dispatch.
      #
      # @param type [Integer] scalar type marker
      # @param reader [Wire::Reader] reader positioned after the type byte
      # @param bytes [String] complete payload retained for missing codecs
      # @param registry [CodecRegistry, nil] application deserializers
      # @return [Object] Rational, application value, or EncodedValue
      # @raise [UnsupportedEncodingError] if the type marker is unsupported
      def self.decode_extended_type(type, reader, bytes, registry)
        case type
        when 9 then reader.q
        when 10 then read_codec(reader, bytes, registry)
        else raise UnsupportedEncodingError, "unsupported Ruby builtin type #{type}"
        end
      end

      # Reads an encoded name and interns it as a Ruby Symbol.
      #
      # @param reader [Wire::Reader] reader at the encoding-name field
      # @return [Symbol] decoded name
      # @raise [InvalidValueError] if the name has invalid bytes for its encoding
      def self.read_symbol(reader)
        name = read_string(reader)
        raise InvalidValueError, "invalid Symbol bytes" unless name.valid_encoding?

        name.to_sym
      rescue EncodingError, ArgumentError => e
        raise InvalidValueError, e.message
      end

      # Reads the zero or one Boolean flag.
      #
      # @param reader [Wire::Reader] reader at the flag
      # @return [Boolean] false for zero, true for one
      # @raise [InvalidValueError] if the flag exceeds one
      def self.read_boolean?(reader)
        flag = reader.byte
        raise InvalidValueError, "invalid Boolean flag" unless flag <= 1

        flag == 1
      end

      # Loads an application payload or retains the complete bytes when its codec is absent.
      # Checks the end of the payload before executing application code.
      #
      # @param reader [Wire::Reader] reader at the codec identifier
      # @param bytes [String] complete original scalar payload
      # @param registry [CodecRegistry, nil] available application deserializers
      # @return [Object, EncodedValue] loaded application value or preserved encoded value
      # @raise [InvalidValueError] if the fields are malformed or extra bytes remain
      # @raise [CodecError] if the load callback fails
      def self.read_codec(reader, bytes, registry)
        codec_id = reader.t
        payload = reader.b
        reader.finish!
        codec = registry&.for_id(codec_id)
        codec ? codec.load(payload) : EncodedValue.new(codec_id: codec_id, bytes: bytes)
      end

      # Encodes finite decimal fields or a marker for infinity or NaN.
      #
      # @param value [BigDecimal] decimal to encode
      # @return [String] binary decimal fields
      # @raise [InvalidValueError] if the decimal reports a base other than ten
      def self.decimal_bytes(value)
        return "\x03".b if value.nan?
        return value.positive? ? "\x01".b : "\x02".b if value.infinite?

        # @type var parts: [Integer, String, Integer, Integer]
        parts = value.split
        sign = parts[0]
        digits = parts[1]
        base = parts[2]
        exponent = parts[3]
        raise InvalidValueError, "decimal base must be ten" unless base == 10

        "\x00".b + (sign.negative? ? "\x01".b : "\x00".b) + Wire.t(digits) + Wire.z(exponent)
      end

      # Reconstructs an exact Time instant and restores its fixed offset or UTC state.
      #
      # @param reader [Wire::Reader] reader at the instant field
      # @return [Time] reconstructed time
      # @raise [InvalidValueError] if the offset or UTC flag is inconsistent
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

      # Reads and validates a Date calendar-reform boundary.
      #
      # @param reader [Wire::Reader] reader at the calendar-start field
      # @return [Float] infinite boundary or supported Julian reform day
      # @raise [InvalidValueError] if a finite boundary is outside the supported range
      def self.read_start(reader)
        start = reader.f64
        raise InvalidValueError, "invalid calendar start" unless start.infinite? || (2_298_874..2_426_355).cover?(start)

        start
      end

      # Reconstructs DateTime from its exact astronomical day, offset, and calendar start.
      #
      # @param reader [Wire::Reader] reader at the instant field
      # @return [DateTime] reconstructed date and time
      # @raise [InvalidValueError] if the offset exceeds one day or contains fractional seconds
      def self.read_datetime(reader)
        instant = reader.q
        offset = reader.q
        start = read_start(reader)
        raise InvalidValueError, "invalid DateTime offset" unless offset.abs <= 1 && (offset * 86_400).denominator == 1

        day, fraction = (instant + Rational(1, 2) + offset).divmod(1)
        # @type var date: DateTime
        date = DateTime.jd(day.to_i, 0, 0, 0, offset, start)
        date + fraction
      end

      # Selects a finite decimal reader or constructs the encoded special value.
      #
      # @param reader [Wire::Reader] reader at the decimal-kind byte
      # @return [BigDecimal] finite number, infinity, or NaN
      # @raise [InvalidValueError] if the decimal-kind byte is unknown
      def self.read_decimal(reader)
        case reader.byte
        when 0 then read_finite_decimal(reader)
        when 1 then build_decimal("Infinity")
        when 2 then build_decimal("-Infinity")
        when 3 then build_decimal("NaN")
        else raise InvalidValueError, "invalid decimal kind"
        end
      end

      # Checks canonical digits and verifies that Ruby can represent the stored decimal exponent.
      #
      # @param reader [Wire::Reader] reader at the sign field
      # @return [BigDecimal] reconstructed finite decimal
      # @raise [InvalidValueError] if digits, sign, exponent, or the reconstructed fields are invalid
      def self.read_finite_decimal(reader)
        sign = reader.byte
        digits = reader.t
        exponent = reader.z
        unless sign <= 1 && /\A(?:0|[1-9](?:[0-9]*[1-9])?)\z/.match?(digits) && (digits != "0" || exponent.zero?)
          raise InvalidValueError, "invalid finite decimal fields"
        end

        text = "#{"-" if sign == 1}0.#{digits}e#{exponent}"
        value = build_decimal(text)
        # @type var fields: [Integer, String, Integer, Integer]
        fields = value.split
        if fields != [sign == 1 ? -1 : 1, digits, 10, exponent]
          raise InvalidValueError, "decimal is outside the supported exponent range"
        end

        value
      end

      # Constructs a decimal while temporarily disabling BigDecimal exception flags.
      # The previous exception mode is restored after construction.
      #
      # @param text [String] BigDecimal numeric representation
      # @return [BigDecimal] constructed decimal
      def self.build_decimal(text)
        BigDecimal.save_exception_mode do
          BigDecimal.mode(BigDecimal::EXCEPTION_ALL, false)
          BigDecimal(text)
        end
      end

      # Restores the named encoding without transcoding or validating the original string bytes.
      #
      # @param reader [Wire::Reader] reader at the UTF-8 encoding name
      # @return [String] bytes labelled with the stored Ruby encoding
      # @raise [UnsupportedEncodingError] if Ruby does not recognize the encoding name
      def self.read_string(reader)
        name = reader.t
        bytes = reader.b
        begin
          encoding = Encoding.find(name)
        rescue ArgumentError => e
          raise UnsupportedEncodingError, e.message
        end
        raise UnsupportedEncodingError, "unknown encoding #{name}" unless encoding

        bytes.force_encoding(encoding)
      end
      private_class_method :decode_payload, :read_string, :decimal_bytes, :read_time, :read_start,
                           :read_datetime, :read_decimal, :builtin_slot, :builtin_payload, :time_bytes,
                           :checked_builtin, :decimal_payload,
                           :checked_object_builtin, :decode_type, :decode_extended_type, :read_symbol,
                           :read_boolean?,
                           :read_codec, :read_finite_decimal, :build_decimal
    end
  end
end
