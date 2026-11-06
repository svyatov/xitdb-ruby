# frozen_string_literal: true

module XitDB
  module Ruby
    # Indexes immutable codec registrations by exact class and stored identifier.
    # Subclasses do not inherit a codec registration. Built-in values and collection classes cannot be overridden.
    class CodecRegistry
      # Frozen copy of the validated registrations.
      #
      # @return [Array<Codec>] frozen copy of the validated registrations
      attr_reader :codecs

      # Copies registrations and builds frozen lookup tables.
      #
      # @param codecs [Array<Codec>] immutable codec values with distinct identifiers and exact types
      # @raise [CodecConfigurationError] if registrations are invalid, duplicated, or override built-in types
      def initialize(codecs)
        unless Object.instance_method(:instance_of?).bind_call(codecs, ::Array)
          raise CodecConfigurationError, "codecs must be an Array"
        end

        @codecs = ::Array.instance_method(:map).bind_call(codecs) { |codec| codec }.freeze
        # @type var by_type: Hash[Class, Codec]
        by_type = {}
        @by_type = by_type.compare_by_identity
        # @type ivar @by_id: Hash[String, Codec]
        @by_id = {}
        @codecs.each do |codec|
          validate_registration(codec)
          @by_type[codec.type] = codec
          @by_id[codec.id] = codec
        end
        @by_type.freeze
        @by_id.freeze
        freeze
      rescue UnsupportedValueError => e
        raise CodecConfigurationError, e.message
      end

      # Checks one registration against built-in types and entries already indexed.
      #
      # @param codec [Codec] frozen registration to validate
      # @return [void]
      # @raise [CodecConfigurationError] if the codec is invalid, duplicated, or overrides a reserved type
      def validate_registration(codec)
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
      end

      # Finds the codec registered for the exact class of a value.
      #
      # @param value [Object] candidate application value
      # @return [Codec, nil] matching registration, or nil when unregistered
      def for_value(value)
        @by_type[Object.instance_method(:class).bind_call(value)]
      end

      # Finds the codec named by a stored payload.
      #
      # @param id [String] stored codec identifier
      # @return [Codec, nil] matching registration, or nil when unavailable
      def for_id(id)
        @by_id[id]
      end
    end
  end
end
