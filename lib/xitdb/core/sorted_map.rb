# frozen_string_literal: true

module XitDB
  module Core
    # A map that orders binary string keys by their bytes.
    #
    # A counted tree supports key lookup, insertion rank, and indexed access.
    #
    # Iteration yields binary key strings and stored value slots, including empty value slots for sets.
    class SortedMap
      include Enumerable

      # @!attribute [r] cursor
      #   View locating this collection.
      #   @return [Cursor]
      attr_reader :cursor

      # Opens a map or set whose keys follow binary byte order.
      # @param cursor [Cursor] view locating this collection or value
      # @param set [Boolean] whether a new collection stores keys without values
      # @return [SortedMap]
      # @raise [InvalidValueError] if the cursor holds an incompatible collection tag
      def initialize(cursor, set: false)
        @cursor = cursor
        tag = if cursor.slot.tag == :none
                set ? :sorted_set : :sorted_map
              else
                cursor.slot.tag
              end
        raise InvalidValueError, "slot does not contain a sorted collection" unless %i[sorted_map
                                                                                       sorted_set].include?(tag)

        @tree = Tree.new(cursor, tag: tag)
      end

      # Returns the total number of keys.
      # @return [Integer]
      def size
        @tree.size
      end

      # Reads the value for an exact binary key.
      # @param key_bytes [String] binary key compared in byte order
      # @return [Slot, nil]
      def get(key_bytes)
        entry = @tree.find(key_bytes)
        @tree.record(entry).last if entry
      end

      # Tests whether an exact binary key exists.
      # @param key_bytes [String] binary key compared in byte order
      # @return [Boolean]
      def include?(key_bytes)
        !@tree.find(key_bytes).nil?
      end

      # Stores or replaces a value for a binary key.
      # @param key_bytes [String] binary key compared in byte order
      # @param value [Slot] value slot to store
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      def put(key_bytes, value:)
        replace_child(key_bytes, value)
      end

      # Adds a binary key without replacing an existing entry.
      # @param key_bytes [String] binary key compared in byte order
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      def add(key_bytes)
        @tree.store(key_bytes, key_only: true)
        self
      end

      # Removes an exact key and invalidates its value views.
      # @param key_bytes [String] binary key compared in byte order
      # @return [Boolean]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      def remove(key_bytes)
        @tree.remove(key_bytes)
      end

      # Counts keys strictly smaller than this key, including when the key is absent.
      # @param key_bytes [String] binary key compared in byte order
      # @return [Integer]
      def rank(key_bytes)
        @tree.locate(key_bytes).last
      end

      # Reads a pair by sorted index, counting negative indexes from the end.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [Array(String, Slot), nil]
      def at(index)
        entry = @tree.at(index)
        decode(entry) if entry
      end

      # Visits key and value pairs in ascending binary key order.
      # @return [self, Enumerator<Array>]
      # @yield [entry] receives the binary key and value slot as a pair
      # @yieldparam entry [Array(String, Slot)] binary key and stored value slot
      # @yieldreturn [Object] ignored
      # @note Without a block, returns an Enumerator.
      def each(&block)
        return enum_for(:each) unless block

        each_from_index(0, &block)
      end

      # Visits pairs from the first key greater than or equal to the supplied key.
      # @param key_bytes [String] binary key compared in byte order
      # @return [self, Enumerator<Array>]
      # @yield [entry] receives the binary key and value slot as a pair
      # @yieldparam entry [Array(String, Slot)] binary key and stored value slot
      # @yieldreturn [Object] ignored
      # @note Without a block, returns an Enumerator.
      def each_from(key_bytes, &block)
        return enum_for(:each_from, key_bytes) unless block

        each_from_index(rank(key_bytes), &block)
      end

      # Visits sorted pairs from an index, counting negative indexes from the end.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [self, Enumerator<Array>]
      # @yield [entry] receives the binary key and value slot as a pair
      # @yieldparam entry [Array(String, Slot)] binary key and stored value slot
      # @yieldreturn [Object] ignored
      # @note Without a block, returns an Enumerator.
      def each_from_index(index)
        return enum_for(:each_from_index, index) unless block_given?

        @tree.each_from_index(index) { |entry| yield decode(entry) }
        self
      end

      # Finds a value view, optionally creating a key with an empty value.
      # @param key_bytes [String] binary key compared in byte order
      # @param create [Boolean] whether to create an empty element when the requested position is absent
      # @return [Cursor, nil]
      def cursor_at(key_bytes, create: false)
        slot = get(key_bytes)
        if !slot && create
          add(key_bytes)
          slot = get(key_bytes)
        end
        cursor.hash_child(key_bytes.b.freeze, slot) if slot
      end

      # Stores a child value and forwards ownership and propagation options.
      # @param key_bytes [String] binary key compared in byte order
      # @param slot [Slot] stored value or record descriptor
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @api private
      def replace_child(key_bytes, slot, **)
        @tree.store(key_bytes, value: slot, **)
        self
      end

      private

      # Reads a sorted entry into its binary key and value slot.
      def decode(entry)
        key, value = @tree.record(entry)
        [cursor.database.read_bytes(key, bound: cursor.bound).bytes, value]
      end
    end

    # A byte-ordered set of binary string keys.
    class SortedSet < SortedMap
      # Opens a sorted key-only collection.
      # @param cursor [Cursor] view locating this collection or value
      # @return [SortedSet]
      # @raise [InvalidValueError] if the cursor holds an incompatible collection tag
      def initialize(cursor)
        super(cursor, set: true)
      end
    end
  end
end

require_relative "sorted_map/tree"
