# frozen_string_literal: true

require_relative "../ruby/codec"

module XitDB
  module Profiles
    # Preserves Ruby scalar types and collection ordering.
    class Ruby
      attr_reader :hasher, :codecs

      def initialize(codecs: [])
        @registry = XitDB::Ruby::CodecRegistry.new(codecs)
        @codecs = @registry.codecs
        @hasher = Core::Hasher.new(id: "rb01", size: 32) { |bytes| Digest::SHA256.digest(bytes) }
        freeze
      end

      def encode(value, context:, path:)
        ValueWalker.encode(value, context: context, path: path)
      end

      def encode_scalar(value, core:)
        XitDB::Ruby::Scalars.encode(value, core: core, registry: @registry)
      end

      def decode(slot, context:, path:, immutable: true)
        if (adapter = container(slot, context: context, path: path))
          context.view(slot, path: path, kind: adapter.kind)
        else
          XitDB::Ruby::Scalars.decode(slot, core: context.database.core, bound: context.read_bound,
                                            registry: @registry, immutable: immutable)
        end
      end

      def key_bytes(value)
        XitDB::Ruby::KeyEncoding.dump(value)
      end

      def container(slot, context:, path:)
        return nil unless slot.tag == :array_list || (slot.empty? && path.empty?)

        XitDB::Ruby::Containers.new(self, context.cursor(slot), context: context, path: path)
      end

      def empty_container(kind, context:, path:)
        kind, key_kind = kind if kind.is_a?(::Array)
        XitDB::Ruby::Containers.new(self, context.cursor(Core::Slot.new), context: context, path: path,
                                                                          kind: kind, key_kind: key_kind)
      end

      def conversion_kind(adapter)
        return adapter.kind unless %i[sorted_map sorted_set].include?(adapter.kind)

        stored = Core::ArrayList.new(adapter.cursor).get(1)
        raise InvalidValueError, "missing sorted key kind" unless stored

        key = stored.value
        [adapter.kind, XitDB::Ruby::Containers::KEY_KINDS.key(key)]
      end

      def conversion_container(kind, context:, path:)
        # @type var kind: Symbol | [Symbol, Symbol?]
        kind = [kind, :string] if kind.is_a?(Symbol) && %i[sorted_map sorted_set].include?(kind)
        empty_container(kind, context: context, path: path)
      end

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

      def copy_conversion_bytes(source, encoding, context:, path:)
        if source.format_tag == "rb"
          raise UnsupportedValueError.new("portable rb bytes require an explicit transform", path: path)
        end
        return source.write_to(context) if !encoding || encoding == :binary

        encoding = source.portable_encoding if encoding == :portable
        prefix = "\x01\x01".b + XitDB::Ruby::Wire.t(encoding.name) + XitDB::Ruby::Wire.u(source.size)
        source.write_to(context, prefix: prefix, format_tag: "rb")
      end

      def input_kind(value, path:)
        InputGuard.check!(value, path: path)
        return nil if @registry.for_value(value)

        klass = Object.instance_method(:class).bind_call(value)
        case value
        when Hash, ::Array, ::Set
          validate_container(value, klass, path)
          { Hash => :map, ::Array => :array, ::Set => :set }.fetch(klass)
        when CollectionDeclaration
          declaration_kind(value, klass, path)
        end
      end

      def hash_defaults?(value)
        default = !BasicObject.instance_method(:equal?).bind_call(value.default, nil)
        !value.default_proc.nil? || default || value.compare_by_identity?
      end

      def validate_container(value, klass, path)
        unless [Hash, ::Array, ::Set].include?(klass)
          raise UnsupportedValueError.new("container subclasses are unsupported", path: path)
        end
        if value.is_a?(Hash) && hash_defaults?(value)
          raise UnsupportedValueError.new("Hash defaults and identity comparison are unsupported", path: path)
        end
        return unless value.is_a?(::Set) && value.compare_by_identity?

        raise UnsupportedValueError.new("Set identity comparison is unsupported", path: path)
      end

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
