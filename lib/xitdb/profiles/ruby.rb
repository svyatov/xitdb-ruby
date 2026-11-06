# frozen_string_literal: true

require_relative "../ruby/codec"

module XitDB
  module Profiles
    # Connects Ruby values to scalar encoders and collection adapters.
    # Maps and sets preserve insertion order; typed sorted collections preserve their declared key order.
    # SHA-256 hashes canonical key bytes under the "rb01" header identifier.
    # Application codecs belong to this profile instance and are not written as executable code.
    class Ruby
      attr_reader :hasher, :codecs

      # @!attribute [r] hasher
      #   SHA-256 hasher with the Ruby profile identifier.
      #
      #   @return [Core::Hasher] SHA-256 hasher with the Ruby profile identifier
      # @!attribute [r] codecs
      #   Frozen validated application registrations.
      #
      #   @return [Array<XitDB::Ruby::Codec>] frozen validated application registrations

      # Validates application codecs and selects the Ruby profile SHA-256 hasher.
      #
      # @param codecs [Array<XitDB::Ruby::Codec>] serializers for exact application classes
      # @raise [CodecConfigurationError] if registrations are invalid or conflict
      def initialize(codecs: [])
        @registry = XitDB::Ruby::CodecRegistry.new(codecs)
        @codecs = @registry.codecs
        @hasher = Core::Hasher.new(id: "rb01", size: 32) { |bytes| Digest::SHA256.digest(bytes) }
        freeze
      end

      # Walks a Ruby value tree and stores each scalar and collection through this profile.
      #
      # @param value [Object] source value or nested collection
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] logical location used in errors
      # @return [Core::Slot] stored root of the encoded value
      # @raise [ValueError] if an input value, key, or collection cannot be represented
      def encode(value, context:, path:)
        ValueWalker.encode(value, context: context, path: path)
      end

      # Delegates built-in and application scalar storage to the Ruby encoder.
      #
      # @param value [Object] supported scalar or registered application value
      # @param core [Core::Database] destination storage
      # @return [Core::Slot] stored scalar descriptor
      # @raise [ValueError] if the scalar cannot be represented
      def encode_scalar(value, core:)
        XitDB::Ruby::Scalars.encode(value, core: core, registry: @registry)
      end

      # Returns a lazy view for collections and a decoded Ruby object for scalars.
      #
      # @param slot [Core::Slot] stored value descriptor
      # @param context [Context] source snapshot or transaction context
      # @param path [Array<Object>] logical location of the value
      # @param immutable [Boolean] whether decoded scalar objects are frozen
      # @return [Object] collection view or scalar
      # @raise [ValueError] if stored data cannot be decoded by this profile
      def decode(slot, context:, path:, immutable: true)
        if (adapter = container(slot, context: context, path: path))
          context.view(slot, path: path, kind: adapter.kind)
        else
          XitDB::Ruby::Scalars.decode(slot, core: context.database.core, bound: context.read_bound,
                                            registry: @registry, immutable: immutable)
        end
      end

      # Builds canonical bytes for Ruby map and set key identity.
      #
      # @param value [nil, Boolean, Integer, Float, String, Symbol] supported exact key class
      # @return [String] frozen binary identity bytes
      # @raise [UnsupportedValueError] if the key type or value is unsupported
      def key_bytes(value)
        XitDB::Ruby::KeyEncoding.dump(value)
      end

      # Recognizes this profile's collection layout and binds it to the context.
      # An empty root is treated as an empty map.
      #
      # @param slot [Core::Slot] candidate collection descriptor
      # @param context [Context] owner of the read or write
      # @param path [Array<Object>] logical collection location
      # @return [XitDB::Ruby::Containers, nil] bound adapter, or nil for a scalar
      def container(slot, context:, path:)
        return nil unless slot.tag == :array_list || (slot.empty? && path.empty?)

        XitDB::Ruby::Containers.new(self, context.cursor(slot), context: context, path: path)
      end

      # Creates an adapter for a new empty collection at a logical location.
      #
      # @param kind [Symbol, Array(Symbol, Symbol)] collection kind, optionally paired with a sorted key kind
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] logical collection location
      # @return [XitDB::Ruby::Containers] new empty collection adapter
      def empty_container(kind, context:, path:)
        kind, key_kind = kind if kind.is_a?(::Array)
        XitDB::Ruby::Containers.new(self, context.cursor(Core::Slot.new), context: context, path: path,
                                                                          kind: kind, key_kind: key_kind, defer: true)
      end

      # Retains the declared key kind when converting a typed sorted collection.
      #
      # @param adapter [Object] source collection adapter
      # @return [Symbol, Array(Symbol, Symbol)] logical kind, paired with a key kind for sorted collections
      # @raise [InvalidValueError] if the sorted envelope lacks its key-kind field
      def conversion_kind(adapter)
        return adapter.kind unless %i[sorted_map sorted_set].include?(adapter.kind)

        stored = Core::ArrayList.new(adapter.cursor).get(1)
        raise InvalidValueError, "missing sorted key kind" unless stored

        key = stored.value
        [adapter.kind, XitDB::Ruby::Containers::KEY_KINDS.key(key)]
      end

      # Creates a destination collection while copying between profiles.
      #
      # @param kind [Symbol, Array(Symbol, Symbol)] logical collection kind and optional sorted key kind
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] destination collection location
      # @return [XitDB::Ruby::Containers] destination adapter
      def conversion_container(kind, context:, path:)
        # @type var kind: Symbol | [Symbol, Symbol?]
        kind = [kind, :string] if kind.is_a?(Symbol) && %i[sorted_map sorted_set].include?(kind)
        empty_container(kind, context: context, path: path)
      end

      # Exposes byte-backed scalars for conversion without materializing the entire value.
      # Ruby String payloads expose their original bytes and Encoding; other Ruby scalar payloads return nil.
      #
      # @param slot [Core::Slot] candidate scalar descriptor
      # @param context [Context] source snapshot or transaction context
      # @return [Array, nil] pair of byte source and encoding hint, or nil when inapplicable
      def conversion_bytes(slot, context:)
        return unless %i[bytes short_bytes].include?(slot.tag)

        source = Conversion::ByteSource.new(context, slot)
        return [source, :binary] unless source.format_tag
        return [source, nil] unless source.format_tag == "rb"
        return unless source.read(0, [source.size, 2].min) == "\x01\x01".b

        length, position = source.unsigned(2)
        raise UnsupportedEncodingError, "encoding name is too long" if length > Core::Bytes::CHUNK_SIZE

        name = source.read(position, length).force_encoding(Encoding::UTF_8)
        raise InvalidValueError, "invalid encoding name" unless name.valid_encoding?

        begin
          encoding = Encoding.find(name)
        rescue ArgumentError => e
          raise UnsupportedEncodingError, e.message
        end
        size, position = source.unsigned(position + length)
        raise InvalidValueError, "trailing or truncated String bytes" unless position + size == source.size

        [source.slice(position, size), encoding]
      end

      # Copies a streamed scalar into this profile using its encoding hint.
      #
      # @param source [Conversion::ByteSource] bounded source bytes
      # @param encoding [Symbol, Encoding, nil] conversion hint identifying portable, binary, encoded, or tagged bytes
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] destination location used in errors
      # @return [Core::Slot] descriptor for the copied bytes
      # @raise [ValueError] if the source cannot be represented by this profile
      def copy_conversion_bytes(source, encoding, context:, path:)
        if source.format_tag == "rb"
          raise UnsupportedValueError.new("portable rb bytes require an explicit transform", path: path)
        end
        return source.write_to(context) if !encoding || encoding == :binary

        encoding = source.portable_encoding if encoding == :portable
        prefix = "\x01\x01".b + XitDB::Ruby::Wire.t(encoding.name) + XitDB::Ruby::Wire.u(source.size)
        source.write_to(context, prefix: prefix, format_tag: "rb")
      end

      # Validates a candidate collection and identifies its storage kind.
      # Scalar values return nil and are handled by the scalar encoder.
      #
      # @param value [Object] candidate input
      # @param path [Array<Object>] logical input location used in errors
      # @return [Symbol, Array(Symbol, Symbol), nil] recognized kind and optional key kind
      # @raise [UnsupportedValueError] if collection behavior cannot be preserved
      def input_kind(value, path:)
        InputGuard.check!(value, path: path)
        return nil if @registry.for_value(value)

        klass = Object.instance_method(:class).bind_call(value)
        case value
        when Hash, ::Array, ::Set
          validate_container!(value, klass, path)
          { Hash => :map, ::Array => :array, ::Set => :set }.fetch(klass)
        when CollectionDeclaration
          declaration_kind(value, klass, path)
        end
      end

      # Detects Hash settings that this profile cannot preserve.
      #
      # @param value [Hash] input hash
      # @return [Boolean] whether a default value, default procedure, or identity comparison is configured
      def hash_defaults?(value)
        default = !BasicObject.instance_method(:equal?).bind_call(value.default, nil)
        !value.default_proc.nil? || default || value.compare_by_identity?
      end

      # Rejects collection subclasses and comparison or default behavior that cannot be stored.
      #
      # @param value [Hash, Array, Set] input collection
      # @param klass [Class] exact class obtained without application reflection
      # @param path [Array<Object>] logical input location used in errors
      # @return [void]
      # @raise [UnsupportedValueError] if the collection is a subclass or has unsupported behavior
      def validate_container!(value, klass, path)
        unless [Hash, ::Array, ::Set].include?(klass)
          raise UnsupportedValueError.new("container subclasses are unsupported", path: path)
        end
        if value.is_a?(Hash) && hash_defaults?(value)
          raise UnsupportedValueError.new("Hash defaults and identity comparison are unsupported", path: path)
        end
        return unless value.is_a?(::Set) && value.compare_by_identity?

        raise UnsupportedValueError.new("Set identity comparison is unsupported", path: path)
      end

      # Maps an explicit collection declaration to its Ruby-profile kind.
      #
      # @param value [CollectionDeclaration] requested collection layout
      # @param klass [Class] exact declaration class
      # @param path [Array<Object>] logical location used in errors
      # @return [Symbol, Array(Symbol, Symbol)] kind, with the required key kind for sorted collections
      # @raise [UnsupportedValueError] if the declaration is a subclass, unsupported, or lacks a sorted key kind
      def declaration_kind(value, klass, path)
        unless CollectionDeclaration.equal?(klass)
          raise UnsupportedValueError.new("collection declaration subclasses are unsupported", path: path)
        end

        if %i[sorted_map sorted_set].include?(value.kind)
          unless value.key_kind
            raise UnsupportedValueError.new("Ruby sorted collections require an explicit key: kind", path: path)
          end

          return [value.kind, value.key_kind]
        end
        kinds = { hash_map: :map, counted_hash_map: :map, hash_set: :set, counted_hash_set: :set,
                  array_list: :array, linked_array_list: :linked_array }
        kinds.fetch(value.kind) do
          raise UnsupportedValueError.new("unsupported Ruby collection declaration", path: path)
        end
      end

      # Lazily validates keys and produces selectors with their child values.
      # Arrays use integer positions; sets use their members as selectors.
      #
      # @param value [Hash, Array, Set, CollectionDeclaration] input collection
      # @param path [Array<Object>] logical parent location used in key errors
      # @return [Enumerator<Array(Object, Object)>] selector and child-value pairs
      # @raise [ValueError] during enumeration if a key cannot be represented
      def input_entries(value, path:)
        Enumerator.new do |output|
          case value
          when Hash, ::Set
            entries = value.is_a?(Hash) ? value.each_pair : value.each.lazy.map { |member| [member, nil] }
            entries.each do |key, child|
              begin
                key_bytes(key)
              rescue ValueError => e
                raise e.class.new(e.message, path: path + [key]), cause: e
              end
              output << [key, child]
            end
          when ::Array
            value.each_with_index { |child, index| output << [index, child] }
          end
        end
      end
    end
  end
end
