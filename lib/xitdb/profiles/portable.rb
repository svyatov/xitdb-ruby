# frozen_string_literal: true

require_relative "../input_guard"

module XitDB
  # Defines how Ruby objects map to stored scalar values, keys, and collection layouts.
  # The portable profile follows native xitdb layouts; the Ruby profile also preserves Ruby types and insertion order.
  module Profiles
    # Stores a shared subset of Ruby values in native xitdb layouts.
    # Scalars include nil, signed and unsigned 64-bit integers, Float values, and byte strings.
    # Map keys and set members must be Strings and use raw byte identity.
    # Untagged strings decode as UTF-8 when valid and as binary otherwise.
    # Native maps use the configured hasher; sorted collections compare raw key bytes.
    class Portable
      # Maps native storage tags to the logical kinds used by public collection views.
      KINDS = {
        hash_map: :map, counted_hash_map: :map, sorted_map: :sorted_map,
        hash_set: :set, counted_hash_set: :set, sorted_set: :sorted_set,
        array_list: :array, linked_array_list: :linked_array
      }.freeze

      # Hash algorithm for portable maps and sets.
      #
      # @return [Core::Hasher] hash algorithm for portable maps and sets
      attr_reader :hasher

      # Selects the hash algorithm used for portable hash maps and sets.
      #
      # @param hasher [Core::Hasher] algorithm matching the database header, SHA-1 by default
      # @raise [TypeError] if the hasher is not a Core::Hasher
      def initialize(hasher: Core::Hasher.sha1)
        raise TypeError, "hasher must be a Core::Hasher" unless hasher.is_a?(Core::Hasher)

        @hasher = hasher
        freeze
      end

      # Stores one portable scalar using native slots or bytes.
      # Use Core::ByteValue to preserve an explicit byte format tag.
      #
      # @param value [nil, Integer, UInt, Float, String, Core::ByteValue] portable scalar
      # @param core [Core::Database] destination storage
      # @return [Core::Slot] stored scalar descriptor
      # @raise [UnsupportedValueError] if the scalar class or singleton behavior is unsupported
      # @raise [RangeError] if an integer exceeds the native 64-bit range
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

      # Reads a native scalar and restores signed integers and Float bit patterns.
      # Tagged bytes remain Core::ByteValue objects; untagged bytes become UTF-8 or binary Strings.
      #
      # @param slot [Core::Slot] scalar descriptor
      # @param core [Core::Database] source storage
      # @param bound [Integer, nil] exclusive read limit, or the core default
      # @param immutable [Boolean] whether to freeze returned untagged Strings
      # @return [nil, Integer, Float, String, Core::ByteValue] decoded portable value
      # @raise [UnsupportedValueError] if the slot tag is not a portable scalar tag
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

      # Copies a String key as binary bytes and freezes the identity.
      # String encoding labels do not affect portable key identity.
      #
      # @param value [String] portable map key or set member
      # @return [String] frozen binary key bytes
      # @raise [UnsupportedValueError] if the key is not a supported String
      def key_bytes(value)
        InputGuard.check!(value)
        case value
        when String then value.b.freeze
        else raise UnsupportedValueError, "portable keys must be strings"
        end
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

      # Returns a lazy view for collections and a decoded Ruby object for scalars.
      #
      # @param slot [Core::Slot] stored value descriptor
      # @param context [Context] source snapshot or transaction context
      # @param path [Array<Object>] logical location of the value
      # @param immutable [Boolean] whether decoded scalar objects are frozen
      # @return [Object] collection view or scalar
      # @raise [ValueError] if stored data cannot be decoded by this profile
      def decode(slot, context:, path:, immutable: true)
        if (kind = KINDS[slot.tag])
          context.view(slot, path: path, kind: kind)
        else
          decode_scalar(slot, core: context.database.core, bound: context.read_bound, immutable: immutable)
        end
      end

      # Recognizes this profile's collection layout and binds it to the context.
      # An empty root is treated as an empty map.
      #
      # @param slot [Core::Slot] candidate collection descriptor
      # @param context [Context] owner of the read or write
      # @param path [Array<Object>] logical collection location
      # @return [Adapter, nil] bound adapter, or nil for a scalar
      def container(slot, context:, path:)
        return nil unless KINDS.key?(slot.tag) || (slot.empty? && path.empty?)

        Adapter.new(self, context.cursor(slot), context: context, path: path)
      end

      # Creates an adapter for a new empty collection at a logical location.
      #
      # @param kind [Symbol, Array(Symbol, Symbol)] collection kind, optionally paired with a sorted key kind
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] logical collection location
      # @return [Adapter] new empty collection adapter
      def empty_container(kind, context:, path:)
        kind = kind.first if kind.is_a?(Array)
        Adapter.new(self, context.cursor(Core::Slot.new), context: context, path: path, tag: kind)
      end

      # Reports the logical kind to preserve during cross-profile copying.
      #
      # @param adapter [Object] source adapter implementing kind
      # @return [Symbol] logical collection kind
      def conversion_kind(adapter)
        adapter.kind
      end

      # Creates a destination collection while copying between profiles.
      #
      # @param kind [Symbol, Array(Symbol, Symbol)] logical collection kind and optional sorted key kind
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] destination collection location
      # @return [Adapter] destination adapter
      def conversion_container(kind, context:, path:)
        kind = kind.first if kind.is_a?(Array)
        tag = { map: :hash_map, set: :hash_set, array: :array_list, linked_array: :linked_array_list }.fetch(kind, kind)
        empty_container(tag, context: context, path: path)
      end

      # Exposes byte-backed scalars for conversion without materializing the entire value.
      #
      # @param slot [Core::Slot] candidate scalar descriptor
      # @param context [Context] source snapshot or transaction context
      # @return [Array, nil] pair of byte source and encoding hint, or nil when inapplicable
      def conversion_bytes(slot, context:)
        return unless %i[bytes short_bytes].include?(slot.tag)

        source = Conversion::ByteSource.new(context, slot)
        [source, source.format_tag ? nil : :portable]
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
        source.write_to(context, format_tag: encoding ? nil : source.format_tag)
      rescue ValueError => e
        raise e.class.new(e.message, path: path), cause: e
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

      # Lazily validates keys and produces selectors with their child values.
      # Distinct input keys with the same portable bytes raise KeyCollisionError during enumeration.
      # Arrays use integer positions; sets use their members as selectors.
      #
      # @param value [Hash, Array, Set, CollectionDeclaration] input collection
      # @param path [Array<Object>] logical parent location used in key errors
      # @return [Enumerator<Array(Object, Object)>] selector and child-value pairs
      # @raise [ValueError] during enumeration if a key cannot be represented
      # @raise [KeyCollisionError] during enumeration if distinct input keys have identical portable bytes
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

      # Adapts native portable layouts to the shared collection operations.
      # Hash maps and sets visit entries in hash traversal order; sorted collections use byte order.
      # Sequence adapters use integer positions and return encoded child slots for lazy decoding.
      class Adapter
        attr_reader :kind, :cursor

        # @!attribute [r] kind
        #   Logical collection kind used by public views.
        #
        #   @return [Symbol] logical collection kind used by public views
        # @!attribute [r] cursor
        #   Cursor holding the native collection root.
        #
        #   @return [Core::Cursor] cursor holding the native collection root

        # Binds a native collection to a context cursor and logical path.
        #
        # @param profile [Portable] portable scalar and key rules
        # @param cursor [Core::Cursor] collection root cursor
        # @param context [Context] owner of the operation
        # @param path [Array<Object>] logical collection location
        # @param tag [Symbol, nil] native collection tag, or infer it from the cursor
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

        # Returns the collection descriptor held by the adapter cursor.
        #
        # @return [Core::Slot] current stored collection root
        def slot
          cursor.slot
        end

        # Counts the entries visible through this collection adapter.
        #
        # @return [Integer] number of keys, members, or sequence elements
        def size
          @collection.size
        end

        # Checks whether the collection has any entries.
        #
        # @return [Boolean] true when the entry count is zero
        def empty?
          size.zero?
        end

        # Looks up a stored child without decoding its scalar or collection value.
        #
        # @param selector [Object] key, member, or zero-based sequence index
        # @return [Core::Slot, nil] stored child, or nil when absent
        # @raise [TypeError] if a sequence selector is not an Integer
        # @raise [ValueError] if the key or stored layout is invalid
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

        # Stores an encoded child at a key or sequence position.
        # A sequence position equal to size appends the child.
        #
        # @param selector [Object] key, member, or nonnegative sequence index
        # @param stored [Core::Slot] already encoded child value
        # @return [self] this adapter
        # @raise [ValueError] if the key or stored layout is invalid
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

        # Removes a key, set member, or sequence element.
        # Deleting a sequence element shifts the following positions down by one.
        #
        # @param selector [Object] key, member, or nonnegative sequence index
        # @return [Object] underlying removal result, which varies by layout
        # @raise [IndexError] if an array index is outside the collection
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
        # Inserts a stored sequence element and shifts the following positions.
        # Array insertion copies the suffix; linked arrays follow a counted tree path.
        #
        # @param index [Integer] nonnegative insertion position validated by the caller
        # @param stored [Core::Slot] encoded element
        # @return [self] this adapter
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

        # Keeps the first count elements of a sequence.
        #
        # @param count [Integer] retained length validated by the caller
        # @return [self] this adapter
        def truncate(count)
          if kind == :linked_array
            cursor.replace(linked_collection.slice(0, count).cursor.slot)
          else
            array_collection.truncate(count)
          end
          self
        end

        # Builds a stored sequence containing a contiguous range of elements.
        #
        # @param start [Integer] nonnegative start position validated by the caller
        # @param count [Integer] element count validated by the caller
        # @return [Core::Slot] descriptor of the new sequence
        def slice(start, count)
          return linked_collection.slice(start, count).cursor.slot if kind == :linked_array

          output = @profile.empty_container(:array_list, context: @context, path: @path)
          count.times { |index| output.assign(index, required_slot(lookup(start + index))) }
          output.slot
        end

        # Appends the stored elements of another sequence.
        # Two linked arrays can join through their tree structure.
        #
        # @param other [Object] sequence adapter implementing kind, cursor, and each_entry
        # @return [self] this adapter
        def concat(other)
          if kind == :linked_array && other.kind == :linked_array
            cursor.replace(linked_collection.concat(Core::LinkedArrayList.new(other.cursor)).cursor.slot)
          else
            other.each_entry { |_index, stored| assign(size, stored) }
          end
          self
        end

        # Finds the number of sorted keys strictly less than the requested key.
        #
        # @param key [Object] key in the sorted collection's accepted key type
        # @return [Integer] zero-based position, including the insertion position for an absent key
        def rank(key)
          sorted_collection.rank(@profile.key_bytes(key))
        end

        # Visits sorted entries starting at the first key greater than or equal to the requested key.
        #
        # @param key [Object] lower-bound sorted key
        # @return [self, Enumerator] this adapter with a block, otherwise an enumerator
        # @yield [key, stored] visits an entry in ascending key order
        # @yieldparam key [Object] decoded key
        # @yieldparam stored [Core::Slot] encoded child value
        # @yieldreturn [void] ignored
        def each_from(key)
          return enum_for(:each_from, key) unless block_given?

          sorted_collection.each_from(@profile.key_bytes(key)) { |bytes, stored| yield decode_key(bytes), stored }
          self
        end

        # Visits sequence or sorted entries starting at an ordinal position.
        # Negative positions count from the end; positions outside the collection visit no entries.
        #
        # @param index [Integer] starting ordinal position
        # @return [self, Enumerator] this adapter with a block, otherwise an enumerator
        # @yield [selector, stored] visits each remaining entry
        # @yieldparam selector [Object] key or sequence position
        # @yieldparam stored [Core::Slot] encoded child value
        # @yieldreturn [void] ignored
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

        # Visits every entry in the order defined by the collection layout.
        #
        # @return [self, Enumerator] this adapter with a block, otherwise an enumerator
        # @yield [selector, stored] visits one entry
        # @yieldparam selector [Object] decoded key or integer sequence position
        # @yieldparam stored [Core::Slot] encoded child value
        # @yieldreturn [void] ignored
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

        # Requires an Integer selector before passing an index to core storage.
        #
        # @param selector [Object] candidate sequence position
        # @return [Integer] supplied index
        # @raise [TypeError] if the selector is not an Integer
        def index_selector(selector)
          raise TypeError, "index must be an Integer" unless selector.is_a?(Integer)

          selector
        end

        # Requires a stored child where the collection structure promises one.
        #
        # @param slot [Core::Slot, nil] result of an internal child lookup
        # @return [Core::Slot] present child
        # @raise [CorruptionError] if the promised child is absent
        def required_slot(slot)
          raise CorruptionError, "missing collection slot" unless slot

          slot
        end

        # Checks the active layout before using its collection-specific operations.
        #
        # @return [Core::ArrayList] typed underlying collection
        # @raise [CorruptionError] if the active layout has the wrong collection type
        def array_collection
          collection = @collection
          raise CorruptionError, "unexpected collection layout" unless collection.is_a?(Core::ArrayList)

          collection
        end

        # Checks the active layout before using its collection-specific operations.
        #
        # @return [Core::LinkedArrayList] typed underlying collection
        # @raise [CorruptionError] if the active layout has the wrong collection type
        def linked_collection
          collection = @collection
          raise CorruptionError, "unexpected collection layout" unless collection.is_a?(Core::LinkedArrayList)

          collection
        end

        # Checks the active layout before using its collection-specific operations.
        #
        # @return [Core::SortedMap] typed underlying collection
        # @raise [CorruptionError] if the active layout has the wrong collection type
        def sorted_collection
          collection = @collection
          raise CorruptionError, "unexpected collection layout" unless collection.is_a?(Core::SortedMap)

          collection
        end

        # Checks the active layout before using hash-specific operations.
        #
        # @return [Core::HashMap] native hash map or set
        # @raise [CorruptionError] if the active layout is not a hash collection
        def hash_collection
          collection = @collection
          raise CorruptionError, "unexpected collection layout" unless collection.is_a?(Core::HashMap)

          collection
        end

        # Checks the active layout before using its collection-specific operations.
        #
        # @return [Core::ArrayList, Core::LinkedArrayList] typed underlying collection
        # @raise [CorruptionError] if the active layout has the wrong collection type
        def sequence_collection
          collection = @collection
          unless collection.is_a?(Core::ArrayList) || collection.is_a?(Core::LinkedArrayList)
            raise CorruptionError, "unexpected sequence layout"
          end

          collection
        end

        # Encodes a selector and attaches its logical path to value errors.
        #
        # @param selector [Object] key or member to encode
        # @return [String] canonical binary key bytes
        # @raise [ValueError] if the key is unsupported for this collection
        def key_bytes(selector)
          @profile.key_bytes(selector)
        rescue ValueError => e
          raise e.class.new(e.message, path: @path + [selector]), cause: e
        end

        # Decodes raw sorted-key bytes as UTF-8 when valid, or binary otherwise.
        #
        # @param bytes [String] stored raw key bytes
        # @return [String] frozen decoded key
        def decode_key(bytes)
          value = bytes.dup.force_encoding(Encoding::UTF_8)
          value.force_encoding(Encoding::BINARY) unless value.valid_encoding?
          value.freeze
        end
      end
    end
  end
end
