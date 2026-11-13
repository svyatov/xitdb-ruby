# frozen_string_literal: true

require_relative "../input_guard"
require_relative "input"

module XitDB
  module Ruby
    # Converts typed sorted keys to bytes that compare in the required order.
    # A sorted collection has one declared kind: string, integer, float, or time.
    # Strings compare by UTF-8 bytes; numbers compare by value; times compare by exact instant.
    # Float zero signs share one position, and NaN has no supported position.
    module OrderedKeys
      # Exact Ruby class accepted for each declared sorted-key kind.
      TYPES = { string: String, integer: Integer, float: Float, time: Time }.freeze

      # Encodes a key for a sorted collection with one declared type.
      #
      # @param value [String, Integer, Float, Time] exact instance of the declared key class
      # @param kind [Symbol] :string, :integer, :float, or :time
      # @return [String] frozen binary bytes with the declared ordering
      # @raise [UnsupportedValueError] if the key has the wrong class, an altered Time, or a NaN value
      # @raise [UnsupportedEncodingError] if a string cannot become valid UTF-8
      def self.dump(value, kind:)
        Input.check!(value)
        value = Input.string(value) if Object.instance_method(:is_a?).bind_call(value, String)
        unless TYPES[kind].equal?(Object.instance_method(:class).bind_call(value))
          raise UnsupportedValueError, "sorted key must match its declared key kind"
        end

        bytes = case value
                when String
                  string_bytes(value)
                when Integer then signed(value, unsigned(value.abs))
                when Time then signed(value.to_r, rational(value.to_r.abs))
                when Float
                  float_bytes(value)
                else
                  raise UnsupportedValueError, "sorted key must match its declared key kind"
                end
        bytes.freeze
      end

      # Converts a string key to the UTF-8 bytes used for ordering.
      #
      # @param value [String] key text
      # @return [String] binary UTF-8 bytes
      # @raise [UnsupportedEncodingError] if transcoding fails or produces invalid UTF-8
      def self.string_bytes(value)
        text = value.encode(Encoding::UTF_8)
        raise UnsupportedEncodingError, "sorted string key must be valid UTF-8" unless text.valid_encoding?

        text.b
      rescue EncodingError => e
        raise UnsupportedEncodingError, "sorted string key cannot convert to UTF-8", cause: e
      end

      # Transforms Float bits so byte order follows numeric order.
      # Both signs of zero use the positive-zero representation.
      #
      # @param value [Float] sortable value
      # @return [String] eight binary bytes
      # @raise [UnsupportedValueError] if the value is NaN
      # @raise [InvalidValueError] if float bits cannot be read as an Integer
      def self.float_bytes(value)
        raise UnsupportedValueError, "NaN keys are unsupported" if value.nan?

        bits = [value.zero? ? 0.0 : value].pack("G").unpack1("Q>")
        raise InvalidValueError, "invalid float key bits" unless bits.is_a?(Integer)

        [bits[63] == 1 ? bits ^ Core::Format::UINT64_MAX : bits ^ (1 << 63)].pack("Q>")
      end

      # Prefixes a nonnegative magnitude with its eight-byte big-endian byte count.
      #
      # @param number [Integer] nonnegative magnitude
      # @return [String] length and magnitude bytes
      # @raise [RangeError] if the magnitude length exceeds an unsigned 64-bit count
      def self.unsigned(number)
        hex = number.to_s(16)
        hex = "0#{hex}" if hex.length.odd?
        magnitude = number.zero? ? "".b : [hex].pack("H*")
        raise RangeError, "ordered integer exceeds physical range" if magnitude.bytesize > Core::Format::UINT64_MAX

        [magnitude.bytesize].pack("Q>") + magnitude
      end

      # Inverts each bit to reverse the byte comparison direction.
      #
      # @param bytes [String] binary field
      # @return [String] complemented bytes
      def self.complement(bytes)
        bytes.bytes.map { |byte| byte ^ 255 }.pack("C*")
      end

      # Adds a sign prefix and reverses the magnitude order for negative values.
      #
      # @param number [Integer, Rational] value whose sign controls the encoding
      # @param body [String] encoding of its positive magnitude
      # @return [String] negative, zero, or positive ordered field
      def self.signed(number, body)
        return "\x01".b if number.zero?

        number.negative? ? "\x00".b + complement(body) : "\x02".b + body
      end

      # Encodes a positive rational through successive division quotients.
      # Alternating complemented fields preserve the order of exact Time instants.
      #
      # @param number [Rational] positive magnitude
      # @return [String] ordered rational bytes
      def self.rational(number)
        numerator = number.numerator
        denominator = number.denominator
        output = +"".b
        inverted = false
        loop do
          quotient, remainder = numerator.divmod(denominator)
          part = unsigned(quotient) + (remainder.zero? ? "\x00".b : "\x01".b)
          output << (inverted ? complement(part) : part)
          break if remainder.zero?

          numerator = denominator
          denominator = remainder
          inverted = !inverted
        end
        output
      end
      private_class_method :unsigned, :complement, :signed, :rational, :string_bytes, :float_bytes
    end
  end
end
