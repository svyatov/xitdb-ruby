# frozen_string_literal: true

require_relative "../input_guard"

module XitDB
  module Ruby
    module OrderedKeys
      TYPES = {string: String, integer: Integer, float: Float, time: Time}.freeze

      def self.dump(value, kind:)
        InputGuard.check!(value)
        unless TYPES.fetch(kind, nil)&.equal?(Object.instance_method(:class).bind_call(value))
          raise UnsupportedValueError, "sorted key must match its declared key kind"
        end

        bytes = case kind
        when :string
          begin
            text = value.encode(Encoding::UTF_8)
            raise UnsupportedEncodingError, "sorted string key must be valid UTF-8" unless text.valid_encoding?

            text.b
          rescue EncodingError => error
            raise UnsupportedEncodingError, "sorted string key cannot convert to UTF-8", cause: error
          end
        when :integer then signed(value) { |number| unsigned(number) }
        when :time then signed(value.to_r) { |number| rational(number) }
        when :float
          raise UnsupportedValueError, "NaN keys are unsupported" if value.nan?

          bits = [value.zero? ? 0.0 : value].pack("G").unpack1("Q>")
          [bits[63] == 1 ? bits ^ Core::Format::UINT64_MAX : bits ^ (1 << 63)].pack("Q>")
        end
        bytes.freeze
      end

      def self.unsigned(number)
        hex = number.to_s(16)
        hex = "0" + hex if hex.length.odd?
        magnitude = number.zero? ? "".b : [hex].pack("H*")
        raise RangeError, "ordered integer exceeds physical range" if magnitude.bytesize > Core::Format::UINT64_MAX

        [magnitude.bytesize].pack("Q>") + magnitude
      end

      def self.complement(bytes)
        bytes.bytes.map { |byte| byte ^ 255 }.pack("C*")
      end

      def self.signed(number)
        return "\x01".b if number.zero?

        body = yield number.abs
        number.negative? ? "\x00".b + complement(body) : "\x02".b + body
      end

      def self.rational(number)
        numerator, denominator = number.numerator, number.denominator
        output = +"".b
        inverted = false
        loop do
          quotient, remainder = numerator.divmod(denominator)
          part = unsigned(quotient) + (remainder.zero? ? "\x00".b : "\x01".b)
          output << (inverted ? complement(part) : part)
          break if remainder.zero?

          numerator, denominator = denominator, remainder
          inverted = !inverted
        end
        output
      end
      private_class_method :unsigned, :complement, :signed, :rational
    end
  end
end
