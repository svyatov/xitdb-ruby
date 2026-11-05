# frozen_string_literal: true

require_relative "../input_guard"

module XitDB
  module Profiles
    # Maps portable values to native xitdb storage layouts.
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
          raise UnsupportedValueError, "unsupported portable scalar: #{Object.instance_method(:class).bind_call(value)}"
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
        case value
        when String then value.b.freeze
        else raise UnsupportedValueError, "portable keys must be strings"
        end
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
        kind = kind.first if kind.is_a?(Array)
        Adapter.new(self, context.cursor(Core::Slot.new), context: context, path: path, tag: kind)
      end

      def conversion_kind(adapter)
        adapter.kind
      end

      def conversion_container(kind, context:, path:)
        kind = kind.first if kind.is_a?(Array)
        tag = { map: :hash_map, set: :hash_set, array: :array_list, linked_array: :linked_array_list }.fetch(kind, kind)
        empty_container(tag, context: context, path: path)
      end

      def conversion_bytes(slot, context:)
        return unless %i[bytes short_bytes].include?(slot.tag)

        source = Conversion::ByteSource.new(context, slot)
        [source, source.format_tag ? nil : :portable]
      end

      def copy_conversion_bytes(source, encoding, context:, path:)
        source.write_to(context, format_tag: encoding ? nil : source.format_tag)
      rescue ValueError => e
        raise e.class.new(e.message, path: path), cause: e
      end

      def input_kind(value, path:)
        InputGuard.check!(value, path: path)
        klass = Object.instance_method(:class).bind_call(value)
        case value
        when Hash, Array, Set
          validate_container(value, klass, path)
          { Hash => :hash_map, Array => :array_list, Set => :hash_set }.fetch(klass)
        when CollectionDeclaration
          if value.key_kind
            raise UnsupportedValueError.new("typed sorted declarations require the Ruby profile", path: path)
          end

          value.kind
        end
      end

      def hash_defaults?(value)
        default = !BasicObject.instance_method(:equal?).bind_call(value.default, nil)
        !value.default_proc.nil? || default || value.compare_by_identity?
      end

      def validate_container(value, klass, path)
        unless [Hash, Array, Set].include?(klass)
          raise UnsupportedValueError.new("container subclasses and singleton behavior are unsupported", path: path)
        end
        if value.is_a?(Hash) && hash_defaults?(value)
          raise UnsupportedValueError.new("Hash defaults and identity comparison are unsupported", path: path)
        end
        return unless value.is_a?(Set) && value.compare_by_identity?

        raise UnsupportedValueError.new("Set identity comparison is unsupported", path: path)
      end

      def input_entries(value, path:)
        Enumerator.new do |output|
          # @type var seen: Hash[String, bool]
          seen = {}
          case value
          when Hash, Set
            entries = value.is_a?(Hash) ? value.each_pair : value.each.lazy.map { |member| [member, member] }
            entries.each do |key, child|
              begin
                bytes = key_bytes(key)
              rescue ValueError => e
                raise e.class.new(e.message, path: path + [key]), cause: e
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

        def empty?
          size.zero?
        end

        def lookup(selector)
          collection = @collection
          if collection.is_a?(Core::ArrayList) || collection.is_a?(Core::LinkedArrayList)
            collection.get(index_selector(selector))
          elsif collection.is_a?(Core::SortedMap)
            collection.get(key_bytes(selector))
          else
            collection.get(@profile.hasher.digest(key_bytes(selector)))
          end
        end

        def assign(selector, stored)
          case kind
          when :array, :linked_array
            if selector == size
              sequence_collection.append(stored)
            else
              sequence_collection.put(index_selector(selector),
                                      stored)
            end
          when :sorted_map
            sorted_collection.put(key_bytes(selector), value: stored)
          when :sorted_set
            sorted_collection.add(key_bytes(selector))
          when :map, :set
            bytes = key_bytes(selector)
            digest = @profile.hasher.digest(bytes)
            key = @context.database.core.bytes(bytes)
            kind == :map ? hash_collection.put(digest, key: key, value: stored) : hash_collection.add(digest, key: key)
          end
          self
        end

        def delete(selector)
          case kind
          when :array
            index = selector
            count = size
            raise IndexError, "array index outside list" unless index.is_a?(Integer) && index >= 0 && index < count

            (index...(count - 1)).each do |position|
              array_collection.put(position, required_slot(array_collection.get(position + 1)))
            end
            array_collection.truncate(count - 1)
          when :linked_array then linked_collection.delete_at(index_selector(selector))
          when :map, :set then hash_collection.remove(@profile.hasher.digest(key_bytes(selector)))
          else sorted_collection.remove(key_bytes(selector))
          end
        end

        # Radix insertion moves the suffix and performs one radix write per slot.
        # Linked insertion follows one count-guided tree path.
        def insert(index, stored)
          if kind == :linked_array
            Core::BTree.new(cursor).insert(index, stored)
          else
            count = size
            array_collection.append(stored)
            (count - 1).downto(index) do |position|
              array_collection.put(position + 1, required_slot(array_collection.get(position)))
            end
            array_collection.put(index, stored)
          end
          self
        end

        def truncate(count)
          if kind == :linked_array
            cursor.replace(linked_collection.slice(0, count).cursor.slot)
          else
            array_collection.truncate(count)
          end
          self
        end

        def slice(start, count)
          return linked_collection.slice(start, count).cursor.slot if kind == :linked_array

          output = @profile.empty_container(:array_list, context: @context, path: @path)
          count.times { |index| output.assign(index, required_slot(lookup(start + index))) }
          output.slot
        end

        def concat(other)
          if kind == :linked_array && other.kind == :linked_array
            cursor.replace(linked_collection.concat(Core::LinkedArrayList.new(other.cursor)).cursor.slot)
          else
            other.each_entry { |_index, stored| assign(size, stored) }
          end
          self
        end

        def rank(key)
          sorted_collection.rank(@profile.key_bytes(key))
        end

        def each_from(key)
          return enum_for(:each_from, key) unless block_given?

          sorted_collection.each_from(@profile.key_bytes(key)) { |bytes, stored| yield decode_key(bytes), stored }
          self
        end

        def each_from_index(index)
          return enum_for(:each_from_index, index) unless block_given?

          index += size if index.negative?
          return self unless index >= 0 && index < size

          case kind
          when :array
            (index...size).each { |position| yield position, required_slot(lookup(position)) }
          when :linked_array
            linked_collection.each_from_index(index).with_index(index) { |stored, position| yield position, stored }
          else
            sorted_collection.each_from_index(index) { |bytes, stored| yield decode_key(bytes), stored }
          end
          self
        end

        def each_entry
          return enum_for(:each_entry) unless block_given?

          case kind
          when :array, :linked_array
            sequence_collection.each.with_index { |stored, index| yield index, stored }
          when :sorted_map, :sorted_set
            sorted_collection.each { |bytes, stored| yield decode_key(bytes), stored }
          else
            hash_collection.each_entry do |_digest, key, stored|
              value = @profile.decode_scalar(key, core: @context.database.core, bound: @context.read_bound)
              raise CorruptionError, "portable map key is not an untagged string" unless value.is_a?(String)

              yield value, stored
            end
          end
          self
        end

        private

        def index_selector(selector)
          raise TypeError, "index must be an Integer" unless selector.is_a?(Integer)

          selector
        end

        def required_slot(slot)
          raise CorruptionError, "missing collection slot" unless slot

          slot
        end

        def array_collection
          collection = @collection
          raise CorruptionError, "unexpected collection layout" unless collection.is_a?(Core::ArrayList)

          collection
        end

        def linked_collection
          collection = @collection
          raise CorruptionError, "unexpected collection layout" unless collection.is_a?(Core::LinkedArrayList)

          collection
        end

        def sorted_collection
          collection = @collection
          raise CorruptionError, "unexpected collection layout" unless collection.is_a?(Core::SortedMap)

          collection
        end

        def hash_collection
          collection = @collection
          raise CorruptionError, "unexpected collection layout" unless collection.is_a?(Core::HashMap)

          collection
        end

        def sequence_collection
          collection = @collection
          unless collection.is_a?(Core::ArrayList) || collection.is_a?(Core::LinkedArrayList)
            raise CorruptionError, "unexpected sequence layout"
          end

          collection
        end

        def key_bytes(selector)
          @profile.key_bytes(selector)
        rescue ValueError => e
          raise e.class.new(e.message, path: @path + [selector]), cause: e
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
