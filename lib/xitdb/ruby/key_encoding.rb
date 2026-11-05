# frozen_string_literal: true

require_relative "wire"
require_relative "../input_guard"

module XitDB
  module Ruby
    # Encodes Ruby hash keys without invoking application equality methods.
    module KeyEncoding
      TYPES = [NilClass, FalseClass, TrueClass, Integer, Float, String, Symbol].freeze
      private_constant :TYPES

      def self.dump(value)
        InputGuard.check!(value)
        unless TYPES.include?(Object.instance_method(:class).bind_call(value))
          raise UnsupportedValueError, "unsupported Ruby key class"
        end

        scalar_bytes(value).freeze
      end

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

      def self.float_bytes(value)
        raise UnsupportedValueError, "NaN keys are unsupported" if value.nan?

        "\x04".b + Wire.f64(value.zero? ? 0.0 : value)
      end

      def self.checked_key(value)
        case value
        when NilClass, FalseClass, TrueClass, String, Integer, Float, Symbol then value
        else raise UnsupportedValueError, "unsupported Ruby key class"
        end
      end

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
