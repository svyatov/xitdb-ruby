# frozen_string_literal: true

require_relative "../../xitdb"
require_relative "scalars"

module XitDB
  module Ruby
    class Codec
      attr_reader :id, :type

      def initialize(id:, type:, dump:, load:)
        unless Object.instance_method(:instance_of?).bind_call(id, String) && Class === type
          raise CodecConfigurationError, "codec requires a String identifier and a Class"
        end
        InputGuard.check!(id)
        @id = String.new(id).encode(Encoding::UTF_8).freeze
        unless @id.valid_encoding? && !@id.empty?
          raise CodecConfigurationError, "codec identifier must be nonempty UTF-8"
        end
        @type = type
        @dump = capture_callback(dump)
        @load = capture_callback(load)
        freeze
      rescue UnsupportedValueError, EncodingError => error
        raise CodecConfigurationError, error.message
      end

      def dump(value)
        bytes = invoke(@dump, value, :dump)
        unless Object.instance_method(:instance_of?).bind_call(bytes, String)
          raise CodecError, "codec #{id} dump must return a byte String"
        end

        String.new(bytes).b
      end

      def load(bytes)
        invoke(@load, String.new(bytes).b.freeze, :load)
      end

      private

      def capture_callback(callback)
        unless Object === callback && Object.instance_method(:public_methods).bind_call(callback).include?(:call)
          raise CodecConfigurationError, "codec callbacks must implement public #call"
        end

        Object.instance_method(:public_method).bind_call(callback, :call)
      end

      def invoke(callback, value, phase)
        callback.call(value)
      rescue XitDB::Error
        raise
      rescue StandardError => error
        raise CodecError, "codec #{id} #{phase} failed: #{error.message}"
      end
    end

    class CodecRegistry
      attr_reader :codecs

      def initialize(codecs)
        unless Object.instance_method(:instance_of?).bind_call(codecs, ::Array)
          raise CodecConfigurationError, "codecs must be an Array"
        end

        @codecs = ::Array.instance_method(:map).bind_call(codecs) { |codec| codec }.freeze
        @by_type = {}.compare_by_identity
        @by_id = {}
        @codecs.each do |codec|
          unless Object.instance_method(:instance_of?).bind_call(codec, Codec) &&
                 Object.instance_method(:frozen?).bind_call(codec)
            raise CodecConfigurationError, "registrations must be immutable Codec values"
          end
          InputGuard.check!(codec)
          unless Module.instance_method(:<=).bind_call(codec.type, Object)
            raise CodecConfigurationError, "codec types must inherit Object"
          end
          if Scalars.builtin_type?(codec.type) || [Hash, ::Array, ::Set, CollectionDeclaration].include?(codec.type) ||
             Module.instance_method(:<=).bind_call(codec.type, Views::Base) ||
             @by_type.key?(codec.type) || @by_id.key?(codec.id)
            raise CodecConfigurationError, "duplicate codec or builtin override: #{codec.id}"
          end

          @by_type[codec.type] = codec
          @by_id[codec.id] = codec
        end
        @by_type.freeze
        @by_id.freeze
        freeze
      rescue UnsupportedValueError => error
        raise CodecConfigurationError, error.message
      end

      def for_value(value)
        @by_type[Object.instance_method(:class).bind_call(value)]
      end

      def for_id(id)
        @by_id[id]
      end
    end
  end
end
