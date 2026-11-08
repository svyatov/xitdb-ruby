# frozen_string_literal: true

module XitDB
  module Ruby
    # Stores bounded maps and sets directly in insertion order.
    # Larger collections and oversized keys use the indexed adapter.
    # @api private
    class PackedMap < Containers
      MAP = 1
      SET = 6
      SCHEMA_MAP = 4
      DICTIONARY = 5
      MAX_MEMBERS = 16
      MAX_KEY_BYTES = 128
      MAX_KEY_PAYLOAD = 256

      # Opens a compact record or creates an unpublished empty collection.
      # Packed records initialize common adapter fields without reading an envelope.
      # rubocop:disable-next Lint/MissingSuper
      def initialize(profile, cursor, context:, path:, kind: nil, defer: false, record: nil, state: nil)
        @profile = profile
        @cursor = cursor
        @context = context
        @path = path
        @kind = kind == :set ? :set : :map
        @deferred = defer
        @state = state
        @schema_slot = nil
        @schema_identity = nil
        @fallback = nil
        @keys = []
        @identities = []
        @key_slots = []
        @values = []
        return if kind || cursor.slot.empty?

        invalid! if cursor.slot.full?
        read_record(record || Core::Record.read(context.database.core, cursor.slot, bound: context.read_bound))
      end

      # Publishes a completed bulk value when its descriptor is requested.
      def slot
        publish if @deferred
        cursor.slot
      end

      def size
        fallback = @fallback
        fallback ? fallback.size : @keys.size
      end

      def lookup(selector)
        fallback = @fallback
        return fallback.lookup(selector) if fallback

        index = @identities.index(key_bytes(selector))
        return nil unless index

        kind == :set ? Core::Slot.null : @values.fetch(index)
      end

      def assign(selector, stored)
        if (fallback = @fallback)
          fallback.assign(selector, stored)
        else
          identity = key_bytes(selector)
          index = @identities.index(identity)
          if index
            @values[index] = stored unless kind == :set
          elsif size == MAX_MEMBERS || identity.bytesize > MAX_KEY_BYTES
            promote(selector, stored)
          else
            append_member(selector, identity, stored)
          end
        end
        publish unless @deferred
        self
      end

      def delete(selector)
        if (fallback = @fallback)
          fallback.delete(selector)
        else
          index = @identities.index(key_bytes(selector))
          return self unless index

          @keys.delete_at(index)
          @identities.delete_at(index)
          @key_slots.delete_at(index)
          @values.delete_at(index)
        end
        publish unless @deferred
        self
      end

      def clear_needed?
        fallback = @fallback
        fallback ? fallback.clear_needed? : size.positive?
      end

      def clear
        if (fallback = @fallback)
          fallback.clear
        else
          @keys.clear
          @identities.clear
          @key_slots.clear
          @values.clear
        end
        publish unless @deferred
        self
      end

      def each_entry(&block)
        return enum_for(:each_entry) unless block

        if (fallback = @fallback)
          fallback.each_entry(&block)
        else
          @keys.each_with_index { |key, index| yield(key, @values.fetch(index)) }
        end
        self
      end

      private

      def append_member(selector, identity, stored)
        @key_slots << @profile.encode_scalar(selector, core: @context.database.core, state: @state, validated: true)
        @keys << (selector.is_a?(String) ? String.new(selector).freeze : selector)
        @identities << identity
        @values << (kind == :set ? Core::Slot.null : stored)
      end

      def each_normalized_index(index)
        if (fallback = @fallback)
          fallback.each_entry.with_index { |entry, position| yield entry[0], entry[1] if position >= index }
        else
          (index...size).each { |position| yield @keys.fetch(position), @values.fetch(position) }
        end
        self
      end

      def read_record(record)
        return read_schema(record.fields) if record.metadata == SCHEMA_MAP

        @kind = case record.metadata
                when MAP then :map
                when SET then :set
                else invalid!
                end
        stride = kind == :set ? 1 : 2
        read_members(record.fields, stride)
      rescue ValueError
        invalid!
      end

      def read_members(fields, stride)
        invalid! unless (fields.size % stride).zero? && fields.size / stride <= MAX_MEMBERS
        (fields.size / stride).times do |index|
          original = fields.fetch(index * stride)
          key = bounded_key(original)
          identity = @profile.stored_key_bytes(key)
          invalid! if identity.bytesize > MAX_KEY_BYTES || @identities.include?(identity)

          @key_slots << original
          @keys << key
          @identities << identity
          @values << (kind == :set ? Core::Slot.null : fields.fetch((index * stride) + 1))
        end
      end

      def read_schema(fields)
        invalid! unless (3..17).cover?(fields.size)
        schema_slot = fields.fetch(0)
        invalid! unless schema_slot.tag == :record && !schema_slot.full?

        schema = @state&.decoded_schemas&.[](schema_slot.value)
        schema ||= decode_schema(schema_slot)
        invalid! unless schema[0].size == fields.size - 1

        @key_slots = schema[0].dup
        @keys = schema[1].dup
        @identities = schema[2].dup
        @values = fields.drop(1)
        @schema_slot = schema_slot
        @schema_identity = @key_slots.map(&:to_bytes).join.b
      end

      def decode_schema(slot)
        record = Core::Record.read(@context.database.core, slot, bound: @context.read_bound)
        invalid! unless record.metadata == DICTIONARY && (2..MAX_MEMBERS).cover?(record.fields.size)
        keys = record.fields.map { |original| bounded_key(original) }
        identities = keys.map { |key| @profile.stored_key_bytes(key) }
        invalid! if identities.any? { |identity| identity.bytesize > MAX_KEY_BYTES }
        invalid! unless identities.uniq.size == identities.size

        # @type var schema: decoded_schema
        schema = [record.fields, keys.freeze, identities.freeze]
        schema.freeze
        @state&.store_decoded_schema(slot.value, schema)
        schema
      end

      def key_bytes(selector)
        @profile.key_bytes(selector, state: @state)
      rescue ValueError => e
        raise e.class.new(e.message, path: @path + [selector]), cause: e
      end

      def bounded_key(slot)
        if %i[bytes short_bytes].include?(slot.tag)
          source = Core::Bytes.open(@context.database.core, slot, bound: @context.read_bound)
          invalid! if source.size > MAX_KEY_PAYLOAD
        end
        decode_key(slot)
      end

      def promote(selector, stored)
        fallback = Containers.new(@profile, @context.cursor(Core::Slot.new), context: @context,
                                                                             path: @path, kind: kind, defer: true)
        @keys.each_with_index { |key, index| fallback.assign(key, @values.fetch(index)) }
        fallback.assign(selector, stored)
        @fallback = fallback
      end

      def publish
        stored = if (fallback = @fallback)
                   fallback.slot
                 else
                   metadata, fields = storage_record
                   Core::Record.append(@context.writable_transaction!, metadata: metadata, fields: fields)
                 end
        cursor.replace(stored)
        @deferred = false
        self
      end

      def storage_record
        if kind == :map && size >= 2
          identity = @key_slots.map(&:to_bytes).join.b
          schema = @schema_slot if @schema_identity == identity
          schema ||= @state&.schema(identity) do
            Core::Record.append(@context.writable_transaction!, metadata: DICTIONARY, fields: @key_slots)
          end
          if schema
            @schema_slot = schema
            @schema_identity = identity
            return [SCHEMA_MAP, [schema, *@values]]
          end
        end
        [kind == :set ? SET : MAP, record_fields]
      end

      def record_fields
        return @key_slots if kind == :set

        # @type var fields: Array[Core::Slot]
        fields = []
        @key_slots.each_with_index { |key, index| fields << key << @values.fetch(index) }
        fields
      end

      def invalid!
        raise InvalidValueError, "invalid packed Ruby map or set"
      end
    end
  end
end
