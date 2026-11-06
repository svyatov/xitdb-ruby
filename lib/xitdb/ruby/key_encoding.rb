# frozen_string_literal: true

require_relative "wire"
require_relative "../input_guard"

module XitDB
  module Ruby
    # Defines key identity for Ruby-profile maps and sets through canonical bytes.
    # A type prefix keeps values such as Integer 1 and Float 1.0 distinct.
    # Positive and negative floating-point zero share an identity; NaN is rejected.
    # Empty strings and ASCII-only strings with ASCII-compatible encodings omit their encoding label.
    # Other strings include their encoding name. These bytes support hashing, not numeric sorting.
    module KeyEncoding
      # Exact scalar classes allowed as ordinary Ruby map keys and set members.
      TYPES = [NilClass, FalseClass, TrueClass, Integer, Float, String, Symbol].freeze
      private_constant :TYPES

      # Validates a built-in key and returns its canonical identity bytes.
      #
      # @param value [nil, Boolean, Integer, Float, String, Symbol] key with an exact supported class
      # @return [String] frozen binary key identity
      # @raise [UnsupportedValueError] if the key has an unsupported class, singleton behavior, or a NaN value
      def self.dump(value)
        InputGuard.check!(value)
        unless TYPES.include?(Object.instance_method(:class).bind_call(value))
          raise UnsupportedValueError, "unsupported Ruby key class"
        end

        scalar_bytes(value).freeze
      end

      # Adds the scalar type prefix and encodes the key body.
      #
      # @param value [nil, Boolean, Integer, Float, String, Symbol] validated key
      # @return [String] binary key identity
      # @raise [UnsupportedValueError] if the value cannot be encoded as a key
      def self.scalar_bytes(value)
        case value
        when nil then "\x00".b
        when false then "\x01".b
        when true then "\x02".b
        when Integer then "\x03".b + Wire.z(value)
        when Float then float_bytes(value)
        when String then "\x05".b + string_body(value)
        when Symbol then "\x06".b + string_body(value.to_s)
        else
          raise UnsupportedValueError, "unsupported Ruby key: #{value.class}"
        end
      end

      # Normalizes both signs of zero before encoding a Float key.
      #
      # @param value [Float] key value
      # @return [String] float type prefix and eight data bytes
      # @raise [UnsupportedValueError] if the value is NaN
      def self.float_bytes(value)
        raise UnsupportedValueError, "NaN keys are unsupported" if value.nan?

        "\x04".b + Wire.f64(value.zero? ? 0.0 : value)
      end

      # Narrows a value to the built-in scalar types that can serve as keys.
      # Exact-class and singleton checks belong to the caller.
      #
      # @param value [Object] candidate scalar
      # @return [nil, Boolean, Integer, Float, String, Symbol] the supplied value
      # @raise [UnsupportedValueError] if the value is outside these scalar types
      def self.checked_key!(value)
        case value
        when NilClass, FalseClass, TrueClass, String, Integer, Float, Symbol then value
        else raise UnsupportedValueError, "unsupported Ruby key class"
        end
      end

      # Encodes the significant encoding label and original string bytes.
      #
      # @param value [String] string key or Symbol name
      # @return [String] length-prefixed encoding label followed by length-prefixed bytes
      def self.string_body(value)
        label = if value.empty? || (value.encoding.ascii_compatible? && value.ascii_only?)
                  ""
                else
                  value.encoding.name
                end
        Wire.t(label) + Wire.b(value)
      end
      private_class_method :string_body, :scalar_bytes, :float_bytes
    end
  end
end
