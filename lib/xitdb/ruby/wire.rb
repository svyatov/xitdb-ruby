# frozen_string_literal: true

require_relative "../errors"

module XitDB
  module Ruby
    # Encodes the fields inside Ruby-profile scalar payloads.
    # Each method returns binary bytes, which callers concatenate into a payload.
    # Unsigned integers use seven data bits per byte, with the high bit marking another byte.
    # Byte strings carry a byte count; signed integers carry a sign and a big-endian magnitude.
    # These fields describe storage and do not define sorted-key order.
    module Wire
      # Encodes a nonnegative integer as a minimal variable-length unsigned field.
      #
      # @param value [Integer] nonnegative number of any size
      # @return [String] binary encoded field
      # @raise [InvalidValueError] if the value is not a nonnegative Integer
      def self.u(value)
        unless value.is_a?(Integer) && value >= 0
          raise InvalidValueError, "unsigned field requires a nonnegative Integer"
        end

        bytes = +"".b
        loop do
          byte = value & 0x7f
          value >>= 7
          bytes << (value.zero? ? byte : byte | 0x80)
          break if value.zero?
        end
        bytes
      end

      # Prefixes raw bytes with their unsigned byte count.
      #
      # @param bytes [String] bytes preserved without transcoding
      # @return [String] binary length and data
      def self.b(bytes)
        u(bytes.bytesize) + bytes.b
      end

      # Converts text to UTF-8 and prefixes it with its byte count.
      #
      # @param text [String] text to transcode
      # @return [String] length-prefixed UTF-8 bytes
      # @raise [InvalidValueError] if conversion fails or UTF-8 bytes are invalid
      def self.t(text)
        utf8 = text.encode(Encoding::UTF_8)
        raise InvalidValueError, "text field requires valid UTF-8" unless utf8.valid_encoding?

        b(utf8)
      rescue EncodingError => e
        raise InvalidValueError, e.message
      end

      # Encodes an integer using a sign byte and a length-prefixed magnitude.
      # Zero has a positive sign and an empty magnitude.
      #
      # @param value [Integer] signed number of any size
      # @return [String] binary signed field
      # @raise [InvalidValueError] if the value is not an Integer
      def self.z(value)
        raise InvalidValueError, "signed field requires an Integer" unless value.is_a?(Integer)

        hex = value.abs.to_s(16)
        hex = "0#{hex}" if hex.length.odd?
        magnitude = value.zero? ? "".b : [hex].pack("H*")
        (value.negative? ? "\x01".b : "\x00".b) + b(magnitude)
      end

      # Encodes a Rational as its signed numerator and unsigned denominator.
      #
      # @param value [Rational] reduced fraction
      # @return [String] binary rational field
      # @raise [InvalidValueError] if the value is not a Rational
      def self.q(value)
        raise InvalidValueError, "rational field requires a Rational" unless value.is_a?(Rational)

        z(value.numerator) + u(value.denominator)
      end

      # Encodes a float as eight IEEE 754 bytes in network byte order.
      #
      # @param value [Float] floating-point value
      # @return [String] eight binary bytes
      def self.f64(value)
        [value].pack("G")
      end
    end
  end
end

require_relative "wire/reader"
