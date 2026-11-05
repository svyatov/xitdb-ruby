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

      # Reads fields sequentially from one binary payload.
      # Each read advances the position. Call {#finish!} after the last field to reject extra bytes.
      # Integer and rational readers reject alternate, nonminimal representations of the same value.
      class Reader
        # Starts reading at the first byte of a payload.
        #
        # @param bytes [String] complete binary payload
        def initialize(bytes)
          @bytes = bytes.b
          @position = 0
        end

        # Reads one unsigned byte.
        #
        # @return [Integer] byte between 0 and 255
        # @raise [InvalidValueError] if the payload ends before the byte
        def byte
          value = take(1).getbyte(0)
          raise InvalidValueError, "truncated payload field" unless value

          value
        end

        # Reads a minimal variable-length unsigned integer.
        #
        # @return [Integer] nonnegative number
        # @raise [InvalidValueError] if the field is truncated or has redundant leading groups
        def u
          value = 0
          shift = 0
          loop do
            part = byte
            value |= (part & 0x7f) << shift
            if part < 0x80
              raise InvalidValueError, "nonminimal unsigned field" if shift.positive? && part.zero?

              return value
            end
            shift += 7
          end
        end

        # Reads a byte count followed by exactly that many bytes.
        #
        # @return [String] binary data without its length prefix
        # @raise [InvalidValueError] if the length or data is truncated
        def b
          take(u)
        end

        # Reads a length-prefixed UTF-8 text field.
        #
        # @return [String] valid UTF-8 text
        # @raise [InvalidValueError] if the field is truncated or contains invalid UTF-8
        def t
          text = b.force_encoding(Encoding::UTF_8)
          raise InvalidValueError, "invalid UTF-8 text field" unless text.valid_encoding?

          text
        end

        # Reads a signed integer and checks its sign and magnitude.
        #
        # @return [Integer] signed number
        # @raise [InvalidValueError] if the sign is invalid, bytes are truncated, or the magnitude is nonminimal
        def z
          sign = byte
          raise InvalidValueError, "invalid integer sign" unless sign <= 1

          magnitude = b
          if magnitude.getbyte(0)&.zero? || (sign == 1 && magnitude.empty?)
            raise InvalidValueError, "nonminimal integer magnitude"
          end

          value = magnitude.empty? ? 0 : magnitude.unpack1("H*").to_s.to_i(16)
          sign.zero? ? value : -value
        end

        # Reads a rational with a positive, reduced denominator.
        #
        # @return [Rational] exact fraction
        # @raise [InvalidValueError] if fields are truncated or the fraction is not reduced with a positive denominator
        def q
          numerator = z
          denominator = u
          unless denominator.positive? && numerator.gcd(denominator) == 1
            raise InvalidValueError, "rational must have a positive reduced denominator"
          end

          Rational(numerator, denominator)
        end

        # Reads eight IEEE 754 bytes in network byte order.
        #
        # @return [Float] decoded floating-point value
        # @raise [InvalidValueError] if eight bytes are unavailable
        def f64
          value = take(8).unpack1("G")
          raise InvalidValueError, "invalid float payload" unless value.is_a?(Float)

          value
        end

        # Checks that the complete payload has been consumed.
        #
        # @return [self] this reader
        # @raise [InvalidValueError] if unread bytes remain
        def finish!
          raise InvalidValueError, "trailing payload bytes" unless @position == @bytes.bytesize

          self
        end

        private

        # Consumes a fixed number of bytes and advances the read position.
        #
        # @param size [Integer] nonnegative byte count
        # @return [String] requested binary bytes
        # @raise [InvalidValueError] if the requested bytes extend past the payload
        def take(size)
          raise InvalidValueError, "truncated payload field" if size > @bytes.bytesize - @position

          result = @bytes.byteslice(@position, size)
          raise InvalidValueError, "truncated payload field" unless result

          @position += size
          result
        end
      end
    end
  end
end
