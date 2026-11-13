# frozen_string_literal: true

require_relative "../input_guard"

module XitDB
  module Ruby
    # Reads built-in contents without invoking per-object method overrides.
    # @api private
    module Input
      CONTENT_TYPES = [String, ::Array, Hash].freeze
      private_constant :CONTENT_TYPES

      def self.check!(value, path: [])
        klass = Object.instance_method(:class).bind_call(value)
        return if CONTENT_TYPES.any? { |type| type.equal?(klass) }

        InputGuard.check!(value, path: path)
      end

      def self.string(value)
        unless Object.instance_method(:instance_of?).bind_call(value, String)
          raise UnsupportedValueError, "String subclasses are unsupported"
        end

        length = String.instance_method(:bytesize).bind_call(value)
        String.instance_method(:byteslice).bind_call(value, 0, length)
      end

      def self.hash_defaults?(value)
        default = Hash.instance_method(:default).bind_call(value)
        procedure = Hash.instance_method(:default_proc).bind_call(value)
        !BasicObject.instance_method(:equal?).bind_call(default, nil) ||
          !BasicObject.instance_method(:equal?).bind_call(procedure, nil) ||
          Hash.instance_method(:compare_by_identity?).bind_call(value)
      end

      def self.entries(value)
        Enumerator.new do |output|
          case value
          when ::Array
            index = 0
            ::Array.instance_method(:each).bind_call(value) do |child|
              output << [index, child]
              index += 1
            end
          when Hash
            Hash.instance_method(:each_pair).bind_call(value) do |key, child|
              output << [key, child]
            end
          end
        end
      end
    end
  end
end
