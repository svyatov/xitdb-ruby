# frozen_string_literal: true

module XitDB
  module Ruby
    # Bounded sharing tables owned by one encode or read-only materialization.
    # Stored offsets never survive transaction rollback or another operation.
    # @api private
    class PackingState
      MAX_SCALARS = 256
      MAX_SCHEMAS = 64
      MAX_BYTES = 64

      attr_reader :scalars, :schemas, :decoded_schemas

      def initialize
        @scalars = {}
        @schemas = {}
        @decoded_schemas = {}
        # @type var frozen_keys: Hash[String, String]
        frozen_keys = {}
        @frozen_keys = frozen_keys.compare_by_identity
      end

      # Reuses validation only for the same immutable exact String object.
      def key_bytes(value, &)
        case value
        when String then string_key_bytes(value, &)
        else yield
        end
      end

      # Includes the exact type, encoding, and bytes in short scalar identity.
      # Input validation belongs to the caller, including cache hits.
      def scalar_identity(value)
        klass = Object.instance_method(:class).bind_call(value)
        return unless String.equal?(klass) || Symbol.equal?(klass)

        text = case value
               when String then value
               when Symbol then value.to_s
               else return
               end
        return if text.bytesize > MAX_BYTES

        # @type var identity: scalar_identity
        identity = [klass, text.encoding, text.b.freeze]
        identity.freeze
      end

      def store_scalar(identity, slot)
        @scalars[identity] = slot if @scalars.size < MAX_SCALARS
        slot
      end

      def schema(identity)
        stored = @schemas[identity]
        return stored if stored
        return if @schemas.size == MAX_SCHEMAS

        @schemas[identity.freeze] = yield
      end

      def store_decoded_schema(offset, schema)
        @decoded_schemas[offset] = schema if @decoded_schemas.size < MAX_SCHEMAS
        schema
      end

      private

      def string_key_bytes(value)
        # @type var length: Integer
        length = String.instance_method(:bytesize).bind_call(value)
        eligible = String.equal?(Object.instance_method(:class).bind_call(value)) &&
                   Object.instance_method(:frozen?).bind_call(value) &&
                   length <= MAX_BYTES
        return @frozen_keys.fetch(value) if eligible && @frozen_keys.key?(value)

        identity = yield
        @frozen_keys[value] = identity if eligible && @frozen_keys.size < MAX_SCALARS
        identity
      end
    end
  end
end
