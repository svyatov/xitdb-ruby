# frozen_string_literal: true

require_relative "../ruby/codec"

module XitDB
  module Profiles
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
        kind, key_kind = kind if ::Array === kind
        XitDB::Ruby::Containers.new(self, context.cursor(Core::Slot.new), context: context, path: path,
                                   kind: kind, key_kind: key_kind)
      end

      def input_kind(value, path:)
        InputGuard.check!(value, path: path)
        return nil if @registry.for_value(value)

        klass = Object.instance_method(:class).bind_call(value)
        case value
        when Hash, ::Array, ::Set
          unless [Hash, ::Array, ::Set].include?(klass)
            raise UnsupportedValueError.new("container subclasses are unsupported", path: path)
          end
          if value.is_a?(Hash) && (value.default_proc || !value.default.nil? || value.compare_by_identity?)
            raise UnsupportedValueError.new("Hash defaults and identity comparison are unsupported", path: path)
          end
          if value.is_a?(::Set) && value.compare_by_identity?
            raise UnsupportedValueError.new("Set identity comparison is unsupported", path: path)
          end
          {Hash => :map, ::Array => :array, ::Set => :set}.fetch(klass)
        when CollectionDeclaration
          unless CollectionDeclaration.equal?(klass)
            raise UnsupportedValueError.new("collection declaration subclasses are unsupported", path: path)
          end
          if %i[sorted_map sorted_set].include?(value.kind)
            unless value.key_kind
              raise UnsupportedValueError.new("Ruby sorted collections require an explicit key: kind", path: path)
            end
            return [value.kind, value.key_kind]
          end
          kinds = {hash_map: :map, counted_hash_map: :map, hash_set: :set, counted_hash_set: :set,
                   array_list: :array, linked_array_list: :linked_array}
          kinds.fetch(value.kind) { raise UnsupportedValueError.new("unsupported Ruby collection declaration", path: path) }
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
              rescue ValueError => error
                raise error.class.new(error.message, path: path + [key]), cause: error
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
