# frozen_string_literal: true

require_relative "../errors"

module XitDB
  module Ruby
    module Wire
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

      def self.b(bytes)
        u(bytes.bytesize) + bytes.b
      end

      def self.t(text)
        utf8 = text.encode(Encoding::UTF_8)
        raise InvalidValueError, "text field requires valid UTF-8" unless utf8.valid_encoding?

        b(utf8)
      rescue EncodingError => error
        raise InvalidValueError, error.message
      end

      def self.z(value)
        raise InvalidValueError, "signed field requires an Integer" unless value.is_a?(Integer)

        hex = value.abs.to_s(16)
        hex = "0" + hex if hex.length.odd?
        magnitude = value.zero? ? "".b : [hex].pack("H*")
        (value.negative? ? "\x01".b : "\x00".b) + b(magnitude)
      end

      def self.q(value)
        raise InvalidValueError, "rational field requires a Rational" unless value.is_a?(Rational)

        z(value.numerator) + u(value.denominator)
      end

      def self.f64(value)
        [value].pack("G")
      end

      class Reader
        def initialize(bytes)
          @bytes = bytes.b
          @position = 0
        end

        def byte
          take(1).getbyte(0)
        end

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

        def b
          take(u)
        end

        def t
          text = b.force_encoding(Encoding::UTF_8)
          raise InvalidValueError, "invalid UTF-8 text field" unless text.valid_encoding?

          text
        end

        def z
          sign = byte
          raise InvalidValueError, "invalid integer sign" unless sign <= 1

          magnitude = b
          if magnitude.getbyte(0) == 0 || (sign == 1 && magnitude.empty?)
            raise InvalidValueError, "nonminimal integer magnitude"
          end

          value = magnitude.empty? ? 0 : magnitude.unpack1("H*").to_i(16)
          sign.zero? ? value : -value
        end

        def q
          numerator = z
          denominator = u
          unless denominator.positive? && numerator.gcd(denominator) == 1
            raise InvalidValueError, "rational must have a positive reduced denominator"
          end

          Rational(numerator, denominator)
        end

        def f64
          take(8).unpack1("G")
        end

        def finish!
          raise InvalidValueError, "trailing payload bytes" unless @position == @bytes.bytesize

          self
        end

        private

        def take(size)
          raise InvalidValueError, "truncated payload field" if size > @bytes.bytesize - @position

          result = @bytes.byteslice(@position, size)
          @position += size
          result
        end
      end
    end
  end
end
