# frozen_string_literal: true

require_relative "../input_guard"

module XitDB
  module Profiles
    class Portable
      KINDS = {
        hash_map: :map, counted_hash_map: :map, sorted_map: :sorted_map,
        hash_set: :set, counted_hash_set: :set, sorted_set: :sorted_set,
        array_list: :array, linked_array_list: :linked_array
      }.freeze

      attr_reader :hasher

      def initialize(hasher: Core::Hasher.sha1)
        raise TypeError, "hasher must be a Core::Hasher" unless hasher.is_a?(Core::Hasher)

        @hasher = hasher
        freeze
      end

      def encode_scalar(value, core:)
        InputGuard.check!(value)
        case value
        when nil then Core::Slot.null
        when UInt then Core::Slot.uint(value.value)
        when Integer
          value > (1 << 63) - 1 ? Core::Slot.uint(value) : Core::Slot.int(value)
        when Float then Core::Slot.float(value)
        when String then core.bytes(value)
        when Core::ByteValue then core.bytes(value.bytes, format_tag: value.format_tag)
        else
          raise UnsupportedValueError, "unsupported portable scalar: #{value.class}"
        end
      end

      def decode_scalar(slot, core:, bound: nil, immutable: true)
        case slot.tag
        when :none then nil
        when :uint then slot.value
        when :int then slot.value >= (1 << 63) ? slot.value - (1 << 64) : slot.value
        when :float then [slot.value].pack("Q>").unpack1("G")
        when :bytes, :short_bytes
          value = core.read_bytes(slot, bound: bound)
          return value if value.format_tag

          bytes = value.bytes.dup.force_encoding(Encoding::UTF_8)
          bytes.force_encoding(Encoding::BINARY) unless bytes.valid_encoding?
          immutable ? bytes.freeze : bytes
        else
          raise UnsupportedValueError, "unsupported portable scalar tag: #{slot.tag}"
        end
      end

      def key_bytes(value)
        InputGuard.check!(value)
        raise UnsupportedValueError, "portable keys must be strings" unless String === value

        value.b.freeze
      end

      def encode(value, context:, path:)
        ValueWalker.encode(value, context: context, path: path)
      end

      def decode(slot, context:, path:, immutable: true)
        if (kind = KINDS[slot.tag])
          context.view(slot, path: path, kind: kind)
        else
          decode_scalar(slot, core: context.database.core, bound: context.read_bound, immutable: immutable)
        end
      end

      def container(slot, context:, path:)
        return nil unless KINDS.key?(slot.tag) || (slot.empty? && path.empty?)

        Adapter.new(self, context.cursor(slot), context: context, path: path)
      end

      def empty_container(kind, context:, path:)
        Adapter.new(self, context.cursor(Core::Slot.new), context: context, path: path, tag: kind)
      end

      def input_kind(value, path:)
        InputGuard.check!(value, path: path)
        klass = Object.instance_method(:class).bind_call(value)
        if Hash === value || Array === value || Set === value
          unless [Hash, Array, Set].include?(klass)
            raise UnsupportedValueError.new("container subclasses and singleton behavior are unsupported", path: path)
          end
          if value.is_a?(Hash) && (value.default_proc || !value.default.nil? || value.compare_by_identity?)
            raise UnsupportedValueError.new("Hash defaults and identity comparison are unsupported", path: path)
          end
          if value.is_a?(Set) && value.compare_by_identity?
            raise UnsupportedValueError.new("Set identity comparison is unsupported", path: path)
          end
          return {Hash => :hash_map, Array => :array_list, Set => :hash_set}.fetch(klass)
        end
        if CollectionDeclaration === value
          if value.key_kind
            raise UnsupportedValueError.new("typed sorted declarations require the Ruby profile", path: path)
          end
          value.kind
        end
      end

      def input_entries(value, path:)
        Enumerator.new do |output|
          seen = {}
          case value
          when Hash, Set
            entries = value.is_a?(Hash) ? value.each_pair : value.each.lazy.map { |member| [member, member] }
            entries.each do |key, child|
              begin
                bytes = key_bytes(key)
              rescue ValueError => error
                raise error.class.new(error.message, path: path + [key]), cause: error
              end
              if seen.key?(bytes)
                raise KeyCollisionError.new("distinct input keys have equal portable bytes", path: path + [key])
              end
              seen[bytes] = true
              output << [key, child]
            end
          when Array
            value.each_with_index { |child, index| output << [index, child] }
          end
        end
      end

      # All knowledge of portable storage layouts stays inside this adapter.
      class Adapter
        attr_reader :kind, :cursor

        def initialize(profile, cursor, context:, path:, tag: nil)
          @profile = profile
          @cursor = cursor
          @context = context
          @path = path
          tag ||= cursor.slot.tag == :none ? :hash_map : cursor.slot.tag
          @kind = KINDS.fetch(tag)
          @collection = case tag
          when :hash_map, :hash_set, :counted_hash_map, :counted_hash_set
            Core::HashMap.new(cursor, counted: %i[counted_hash_map counted_hash_set].include?(tag),
                             set: %i[hash_set counted_hash_set].include?(tag))
          when :array_list then Core::ArrayList.new(cursor)
          when :linked_array_list then Core::LinkedArrayList.new(cursor)
          when :sorted_map, :sorted_set then Core::SortedMap.new(cursor, set: tag == :sorted_set)
          end
        end

        def slot
          cursor.slot
        end

        def size
          @collection.size
        end

        def lookup(selector)
          @collection.get(storage_selector(selector))
        end

        def assign(selector, stored)
          case kind
          when :array, :linked_array
            selector == size ? @collection.append(stored) : @collection.put(selector, stored)
          when :sorted_map
            @collection.put(@profile.key_bytes(selector), value: stored)
          when :sorted_set
            @collection.add(@profile.key_bytes(selector))
          when :map, :set
            bytes = @profile.key_bytes(selector)
            digest = @profile.hasher.digest(bytes)
            key = @context.database.core.bytes(bytes)
            kind == :map ? @collection.put(digest, key: key, value: stored) : @collection.add(digest, key: key)
          end
          self
        end

        def delete(selector)
          case kind
          when :array
            index = selector
            count = size
            raise IndexError, "array index outside list" unless index.is_a?(Integer) && index >= 0 && index < count

            (index...(count - 1)).each { |position| @collection.put(position, @collection.get(position + 1)) }
            @collection.truncate(count - 1)
          when :linked_array then @collection.delete_at(selector)
          else @collection.remove(storage_selector(selector))
          end
        end

        # Radix insertion moves the suffix and performs one radix write per slot.
        # Linked insertion follows one count-guided tree path.
        def insert(index, stored)
          if kind == :linked_array
            Core::BTree.new(cursor).insert(index, stored)
          else
            count = size
            @collection.append(stored)
            (count - 1).downto(index) { |position| @collection.put(position + 1, @collection.get(position)) }
            @collection.put(index, stored)
          end
          self
        end

        def truncate(count)
          if kind == :linked_array
            cursor.replace(@collection.slice(0, count).cursor.slot)
          else
            @collection.truncate(count)
          end
          self
        end

        def slice(start, count)
          return @collection.slice(start, count).cursor.slot if kind == :linked_array

          output = @profile.empty_container(:array_list, context: @context, path: @path)
          count.times { |index| output.assign(index, lookup(start + index)) }
          output.slot
        end

        def concat(other)
          if kind == :linked_array && other.kind == :linked_array
            cursor.replace(@collection.concat(Core::LinkedArrayList.new(other.cursor)).cursor.slot)
          else
            other.each_entry { |_index, stored| assign(size, stored) }
          end
          self
        end

        def rank(key)
          @collection.rank(@profile.key_bytes(key))
        end

        def each_from(key)
          return enum_for(__method__, key) unless block_given?

          @collection.each_from(@profile.key_bytes(key)) { |bytes, stored| yield decode_key(bytes), stored }
          self
        end

        def each_from_index(index)
          return enum_for(__method__, index) unless block_given?

          index += size if index.negative?
          return self unless index >= 0 && index < size

          case kind
          when :array
            (index...size).each { |position| yield position, lookup(position) }
          when :linked_array
            @collection.each_from_index(index).with_index(index) { |stored, position| yield position, stored }
          else
            @collection.each_from_index(index) { |bytes, stored| yield decode_key(bytes), stored }
          end
          self
        end

        def each_entry
          return enum_for(__method__) unless block_given?

          case kind
          when :array, :linked_array
            @collection.each.with_index { |stored, index| yield index, stored }
          when :sorted_map, :sorted_set
            @collection.each { |bytes, stored| yield decode_key(bytes), stored }
          else
            @collection.each_entry do |_digest, key, stored|
              value = @profile.decode_scalar(key, core: @context.database.core, bound: @context.read_bound)
              raise CorruptionError, "portable map key is not an untagged string" unless value.is_a?(String)

              yield value, stored
            end
          end
          self
        end

        private

        def storage_selector(selector)
          return selector if %i[array linked_array].include?(kind)

          bytes = @profile.key_bytes(selector)
          %i[map set].include?(kind) ? @profile.hasher.digest(bytes) : bytes
        rescue ValueError => error
          raise error.class.new(error.message, path: @path + [selector]), cause: error
        end

        def decode_key(bytes)
          value = bytes.dup.force_encoding(Encoding::UTF_8)
          value.force_encoding(Encoding::BINARY) unless value.valid_encoding?
          value.freeze
        end
      end
    end
  end
end
