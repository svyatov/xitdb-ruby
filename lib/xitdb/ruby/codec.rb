# frozen_string_literal: true

require_relative "../../xitdb"
require_relative "scalars"

module XitDB
  module Ruby
    # Defines serialization for one exact application class in the Ruby profile.
    # The dump callback converts a value to bytes; the load callback reconstructs it from frozen binary bytes.
    # The identifier is stored with the payload. Keep it stable and supply the codec when reopening a database.
    # Without its codec, a stored value is returned as an {EncodedValue} that retains the original payload.
    # Codec instances are frozen; callback objects can still hold application state.
    # Load callbacks must return a fresh object and control any mutable objects referenced inside it.
    #
    # @example Register a simple application value
    #   Money = Struct.new(:cents)
    #   codec = XitDB::Ruby::Codec.new(
    #     id: "example/money/v1", type: Money,
    #     dump: ->(money) { money.cents.to_s },
    #     load: ->(bytes) { Money.new(Integer(bytes)) }
    #   )
    #   XitDB::Ruby.memory(codecs: [codec]) do |db|
    #     db.transaction { |root| root[:price] = Money.new(125) }
    #     db.snapshot[:price].cents # => 125
    #   end
    class Codec
      attr_reader :id, :type

      # @!attribute [r] id
      #   Frozen UTF-8 identifier stored in application payloads.
      #
      #   @return [String] frozen UTF-8 identifier stored in application payloads
      # @!attribute [r] type
      #   Exact application class matched by this codec.
      #
      #   @return [Class] exact application class matched by this codec

      # Captures public callback methods and freezes the codec configuration.
      #
      # @param id [String] nonempty identifier converted to UTF-8
      # @param type [Class] exact application class handled by this codec
      # @param dump [#call] callback accepting a value and returning an exact String
      # @param load [#call] callback accepting frozen binary bytes and returning an application value
      # @raise [CodecConfigurationError] if the identifier, type, or callbacks are invalid
      def initialize(id:, type:, dump:, load:)
        unless Object.instance_method(:instance_of?).bind_call(id, String) &&
               Object.instance_method(:is_a?).bind_call(type, Class)
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
      rescue UnsupportedValueError, EncodingError => e
        raise CodecConfigurationError, e.message
      end

      # Calls the serializer and copies its result into a binary string.
      #
      # @param value [Object] application value to serialize
      # @return [String] mutable binary payload copy
      # @raise [CodecError] if the callback fails or returns anything except an exact String
      # @raise [XitDB::Error] if the callback raises a database error
      def dump(value)
        bytes = invoke(@dump, value, :dump)
        case bytes
        when String
          unless Object.instance_method(:instance_of?).bind_call(bytes, String)
            raise CodecError, "codec #{id} dump must return a byte String"
          end
        else
          raise CodecError, "codec #{id} dump must return a byte String"
        end

        String.new(bytes).b
      end

      # Calls the deserializer with an isolated, frozen binary copy of the payload.
      #
      # @param bytes [String] serialized application bytes
      # @return [Object] callback result, without a class check
      # @raise [CodecError] if the callback raises a non-database StandardError
      # @raise [XitDB::Error] if the callback raises a database error
      def load(bytes)
        invoke(@load, String.new(bytes).b.freeze, :load)
      end

      private

      # Captures the public call method so later method replacement does not change this callback.
      #
      # @param callback [#call] callable object
      # @return [Method] captured public call method
      # @raise [CodecConfigurationError] if a public call method is unavailable
      def capture_callback(callback)
        unless Object.instance_method(:is_a?).bind_call(callback, Object) &&
               Object.instance_method(:public_methods).bind_call(callback).include?(:call)
          raise CodecConfigurationError, "codec callbacks must implement public #call"
        end

        Object.instance_method(:public_method).bind_call(callback, :call)
      end

      # Invokes a captured callback and adds codec context to application failures.
      #
      # @param callback [Method] captured serializer or deserializer
      # @param value [Object] callback argument
      # @param phase [Symbol] :dump or :load for error messages
      # @return [Object] callback result
      # @raise [CodecError] if a non-database StandardError escapes the callback
      # @raise [XitDB::Error] preserves database errors from the callback
      def invoke(callback, value, phase)
        callback.call(value)
      rescue XitDB::Error
        raise
      rescue StandardError => e
        raise CodecError, "codec #{id} #{phase} failed: #{e.message}"
      end
    end

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
