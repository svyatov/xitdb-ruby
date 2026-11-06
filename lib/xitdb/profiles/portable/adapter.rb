# frozen_string_literal: true

module XitDB
  module Profiles
    class Portable
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
