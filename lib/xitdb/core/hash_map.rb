# frozen_string_literal: true

module XitDB
  module Core
    # A map indexed by complete binary digests supplied by its caller.
    #
    # The original key and value are stored as slots. The digest, not the key slot, determines entry identity.
    #
    # Branches select four digest bits at a time. Counted variants store size.
    # Other variants count entries by traversal.
    class HashMap
      # Bytes in one digest branch containing sixteen slots.
      BLOCK_SIZE = 16 * Slot::SIZE
      # A zero-filled digest branch with no entries.
      EMPTY_BLOCK = ("\0".b * BLOCK_SIZE).freeze
      # Storage tags supported by the hash map and set reader.
      TAGS = %i[hash_map hash_set counted_hash_map counted_hash_set].freeze

      # @!attribute [r] cursor
      #   View locating this collection.
      #   @return [Cursor]
      attr_reader :cursor

      # Opens a digest-indexed map or set, optionally with a stored entry count.
      # @param cursor [Cursor] view locating this collection or value
      # @param counted [Boolean] whether to store the entry count with the root
      # @param set [Boolean] whether a new collection stores keys without values
      # @return [HashMap]
      # @raise [InvalidValueError] if the cursor holds an incompatible collection tag
      def initialize(cursor, counted: false, set: false)
        @cursor = cursor
        @tag = collection_tag(counted, set)
        slot = cursor.slot
        unless slot.tag == :none || (TAGS.include?(slot.tag) && counted == counted_tag?(slot.tag))
          raise InvalidValueError, "slot does not contain the requested hash collection"
        end

        @tag = slot.tag unless slot.tag == :none
        return unless slot.tag == :none && cursor.transaction

        mutate { |transaction| publish(writable_root(transaction)) }
      end

      # Opens the map or set variant identified by a cursor's slot tag.
      # @param cursor [Cursor] view locating this collection or value
      # @return [HashMap]
      def self.from_cursor(cursor)
        new(cursor, counted: %i[counted_hash_map counted_hash_set].include?(cursor.slot.tag))
      end

      # Reads the value stored for an exact digest.
      # @param hash_bytes [String] precomputed binary digest with the database header hash width
      # @return [Slot, nil]
      def get(hash_bytes)
        entry(hash_bytes)&.last
      end

      # Reads the original key slot stored for an exact digest.
      # @param hash_bytes [String] precomputed binary digest with the database header hash width
      # @return [Slot, nil]
      def key(hash_bytes)
        entry(hash_bytes)&.first
      end

      # Tests whether an entry with this digest exists.
      # @param hash_bytes [String] precomputed binary digest with the database header hash width
      # @return [Boolean]
      def include?(hash_bytes)
        !entry(hash_bytes).nil?
      end

      # Returns the stored count for counted collections, or visits entries to count them.
      # @return [Integer]
      def size
        start = root_pointer
        return 0 unless start

        counted? ? Format.unsigned(read(start, 8)) : each_entry.count
      end

      # Stores a value by digest, preserving an already stored nonempty key.
      # @param hash_bytes [String] precomputed binary digest with the database header hash width
      # @param key [Slot] original key slot retained with the digest
      # @param value [Slot] value slot to store
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      def put(hash_bytes, key:, value:)
        hash_bytes = validate_hash(hash_bytes)
        validate_slot(key)
        validate_slot(value)
        write_entry(hash_bytes, key: key, value: value)
        self
      end

      # Adds a key by digest without replacing an existing value.
      # @param hash_bytes [String] precomputed binary digest with the database header hash width
      # @param key [Slot] original key slot retained with the digest
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      def add(hash_bytes, key:)
        hash_bytes = validate_hash(hash_bytes)
        validate_slot(key)
        write_entry(hash_bytes, key: key, value: nil)
        self
      end

      # Finds a value view, optionally creating empty key and value slots.
      # @param hash_bytes [String] precomputed binary digest with the database header hash width
      # @param create [Boolean] whether to create an empty element when the requested position is absent
      # @return [Cursor, nil]
      def cursor_at(hash_bytes, create: false)
        hash_bytes = validate_hash(hash_bytes)
        value = get(hash_bytes)
        if value.nil? && create
          put(hash_bytes, key: Slot.new, value: Slot.new)
          value = get(hash_bytes)
        end
        return nil unless value

        cursor.hash_child(hash_bytes.freeze, value)
      end

      # Replaces the value of an existing digest entry.
      # @param hash_bytes [String] precomputed binary digest with the database header hash width
      # @param slot [Slot] stored value or record descriptor
      # @param owner [Cursor, nil] child view to preserve during replacement
      # @param collection [Boolean] whether this is an internal copied collection update
      # @param propagate [Boolean] whether to update parent collection paths immediately
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @api private
      def replace_child(hash_bytes, slot, owner: nil, collection: false, propagate: true)
        hash_bytes = validate_hash(hash_bytes)
        validate_slot(slot)
        raise ExpiredViewError, "hash entry was removed" unless include?(hash_bytes)

        write_entry(hash_bytes, key: nil, value: slot, owner: owner, collection: collection, propagate: propagate)
        self
      end

      # Removes a digest entry and invalidates its value views.
      # @param hash_bytes [String] precomputed binary digest with the database header hash width
      # @return [Boolean]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      def remove(hash_bytes) # rubocop:disable Naming/PredicateMethod -- This public method removes an entry.
        hash_bytes = validate_hash(hash_bytes)
        writable!
        return false unless include?(hash_bytes)

        mutate do |transaction|
          start = writable_root(transaction)
          pointer = start + count_bytes
          depth = 0
          # @type var path: Array[[Integer, String, Integer]]
          path = []
          loop do
            block = read(pointer, BLOCK_SIZE)
            index = nibble(hash_bytes, depth)
            slot = parse_slot(Format.slice(block, index * Slot::SIZE, Slot::SIZE))
            path << [pointer, block, index]
            break unless slot.tag == :index

            pointer = slot.value
            depth += 1
          end
          collapse_path(transaction, start, path)
          adjust_count(transaction, start, -1)
          publish(start)
          cursor.invalidate_children(index: hash_bytes)
        end
        true
      end

      # Visits each stored digest, original key slot, and value slot.
      # @return [self, Enumerator<Array>]
      # @yield [hash_bytes, key, value] receives one stored entry
      # @yieldparam hash_bytes [String] stored binary digest
      # @yieldparam key [Slot] original key
      # @yieldparam value [Slot] stored value
      # @yieldreturn [Object] ignored
      # @note Without a block, returns an Enumerator.
      def each_entry
        return enum_for(:each_entry) unless block_given?

        start = root_pointer
        return self unless start

        # @type var stack: Array[[Integer, Integer]]
        stack = [[start + count_bytes, 0]]
        until stack.empty?
          pointer, depth = stack.pop || raise(CorruptionError, "missing hash branch")
          raise CorruptionError, "hash trie exceeds hash width" if depth >= hash_size * 2

          block = read(pointer, BLOCK_SIZE)
          # @type var children: Array[[Integer, Integer]]
          children = []
          16.times do |i|
            slot = parse_slot(Format.slice(block, i * Slot::SIZE, Slot::SIZE))
            if slot.tag == :index
              children << [slot.value, depth + 1]
            elsif slot.tag == :kv_pair
              hash, key, value = read_record(slot)
              yield hash, key, value
            elsif !slot.empty?
              raise CorruptionError, "invalid hash trie entry"
            end
          end
          stack.concat(children.reverse)
        end
        self
      end

      private

      # Selects the storage tag for counted and key-only variants.
      def collection_tag(counted, set)
        if counted
          set ? :counted_hash_set : :counted_hash_map
        else
          set ? :hash_set : :hash_map
        end
      end

      # Checks whether a branch can collapse into its only remaining leaf.
      def collapsible?(pointer, start, entries)
        pointer != start + count_bytes && entries.size <= 1 && entries.none? { |slot| slot.tag == :index }
      end

      # Removes an entry and copies or collapses ancestor blocks.
      def collapse_path(transaction, start, path)
        replacement = Slot.new
        path.reverse_each do |old_pointer, block, index|
          block[index * Slot::SIZE, Slot::SIZE] = replacement.to_bytes
          entries = Array.new(16) { |i| parse_slot(Format.slice(block, i * Slot::SIZE, Slot::SIZE)) }.reject(&:empty?)
          if collapsible?(old_pointer, start, entries)
            replacement = entries.first || Slot.new
          else
            new_pointer = old_pointer < transaction.mutable_start ? transaction.append(block) : old_pointer
            transaction.write_at(new_pointer, block)
            replacement = Slot.new(tag: :index, value: new_pointer)
          end
        end
      end

      # Tests whether a tag includes a stored entry count.
      def counted_tag?(tag)
        %i[counted_hash_map counted_hash_set].include?(tag)
      end

      # Tests whether this collection stores its entry count.
      def counted?
        counted_tag?(@tag)
      end

      # Returns the width of the optional count prefix.
      def count_bytes
        counted? ? 8 : 0
      end

      # Reads the digest width declared by the database header.
      def hash_size
        cursor.database.header.hash_size
      end

      # Checks that a binary digest has the database's declared nonzero width.
      def validate_hash(hash)
        raise TypeError, "hash must be a String" unless hash.is_a?(String)
        raise ArgumentError, "hash has incorrect width" unless hash.bytesize == hash_size && hash_size.positive?

        hash.b
      end

      # Rejects unknown slots and internal branch pointers as keys or values.
      def validate_slot(slot)
        raise TypeError, "expected Slot" unless slot.is_a?(Slot)
        raise CorruptionError, "unknown hash record slot tag" unless Slot::TAGS.include?(slot.tag)
        raise InvalidValueError, "index slot is internal to hash branches" if slot.tag == :index
      end

      # Selects four digest bits, starting at the low bits of the final byte.
      def nibble(hash, depth)
        raise CorruptionError, "hash trie exceeds hash width" if depth >= hash_size * 2

        byte = hash.getbyte(hash_size - 1 - (depth / 2))
        raise CorruptionError, "hash trie exceeds hash width" unless byte

        (byte >> (depth % 2 * 4)) & 15
      end

      # Validates the collection tag and reads its root block.
      def root_pointer
        slot = cursor.slot
        return nil if slot.tag == :none
        raise InvalidValueError, "slot does not contain the requested hash collection" unless slot.tag == @tag

        read(slot.value, count_bytes + BLOCK_SIZE)
        slot.value
      end

      # Reads bytes within the cursor's storage boundary.
      def read(offset, length)
        cursor.database.read_at(offset, length, bound: cursor.bound)
      end

      # Decodes a trie slot and rejects unknown tags.
      def parse_slot(bytes)
        slot = Slot.parse(bytes)
        raise CorruptionError, "unknown hash slot tag" unless Slot::TAGS.include?(slot.tag)

        slot
      end

      # Reads a digest and its original key and value slots.
      def read_record(slot)
        bytes = read(slot.value, hash_size + (Slot::SIZE * 2))
        key = parse_slot(Format.slice(bytes, hash_size, Slot::SIZE))
        value = parse_slot(Format.slice(bytes, hash_size + Slot::SIZE, Slot::SIZE))
        raise CorruptionError, "index slot in hash record" if key.tag == :index || value.tag == :index

        [Format.slice(bytes, 0, hash_size).freeze, key, value]
      end

      # Walks digest branches and checks the full stored digest at a leaf.
      def entry(hash)
        hash = validate_hash(hash)
        start = root_pointer
        return nil unless start

        pointer = start + count_bytes
        depth = 0
        loop do
          block = read(pointer, BLOCK_SIZE)
          slot = parse_slot(Format.slice(block, nibble(hash, depth) * Slot::SIZE, Slot::SIZE))
          return nil if slot.empty?

          if slot.tag == :kv_pair
            stored_hash, key, value = read_record(slot)
            return stored_hash == hash ? [key, value] : nil
          end
          raise CorruptionError, "invalid hash trie entry" unless slot.tag == :index

          pointer = slot.value
          depth += 1
        end
      end

      # Checks cursor validity and requires a writable transaction.
      def writable!
        cursor.slot
        raise ReadOnlyError, "hash collection is read-only" unless cursor.transaction
      end

      # Restores a checkpoint when any part of a trie update fails.
      def mutate
        writable!
        transaction = cursor.transaction
        raise ReadOnlyError, "hash collection is read-only" unless transaction

        checkpoint = transaction.checkpoint
        begin
          yield transaction
        rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
          transaction.restore(checkpoint)
          raise
        else
          transaction.release_checkpoint(checkpoint)
        end
      end

      # Allocates an empty root or copies one below the writable boundary.
      def writable_root(transaction)
        start = root_pointer
        return transaction.append(("\0".b * count_bytes) + EMPTY_BLOCK) unless start

        bytes = read(start, count_bytes + BLOCK_SIZE)
        start < transaction.mutable_start ? transaction.append(bytes) : start
      end

      # Updates the collection cursor to the new root pointer.
      def publish(start, propagate: true)
        cursor.update_collection(Slot.new(tag: @tag, value: start), propagate: propagate)
      end

      # Changes the stored count only for counted collections.
      def adjust_count(transaction, start, delta)
        return unless counted?

        count = Format.unsigned(read(start, 8)) + delta
        Format.integer(count, 0..Format::UINT64_MAX)
        transaction.write_at(start, [count].pack("Q>"))
      end

      # Copies the digest path and writes or replaces its leaf record.
      def write_entry(hash, key:, value:, owner: nil, collection: false, propagate: true)
        mutate do |transaction|
          start = writable_root(transaction)
          pointer = start + count_bytes
          depth = 0
          loop do
            position = pointer + (nibble(hash, depth) * Slot::SIZE)
            slot = parse_slot(read(position, Slot::SIZE))
            if slot.empty? || slot.tag == :kv_pair
              next_pointer = write_leaf(transaction, position, slot, hash, depth, start, key, value)
              break unless next_pointer
            elsif slot.tag == :index
              bytes = read(slot.value, BLOCK_SIZE)
              next_pointer = slot.value < transaction.mutable_start ? transaction.append(bytes) : slot.value
            else
              raise CorruptionError, "invalid hash trie entry"
            end
            transaction.write_at(position, Slot.new(tag: :index, value: next_pointer).to_bytes)
            pointer = next_pointer
            depth += 1
          end
          publish(start, propagate: propagate)
          cursor.invalidate_children(index: hash, except: owner) unless collection || value.nil?
        end
      end

      # Stores a matching digest or adds a branch when digests share a prefix.
      def write_leaf(transaction, position, slot, hash, depth, start, key, value)
        stored_hash, stored_key, stored_value = slot.empty? ? [nil, Slot.new, Slot.new] : read_record(slot)
        if stored_hash.nil? || stored_hash == hash
          next_key = stored_key.empty? && key ? key : stored_key
          next_value = value || stored_value
          record = transaction.append(hash.b + next_key.to_bytes + next_value.to_bytes)
          transaction.write_at(position, Slot.new(tag: :kv_pair, value: record).to_bytes)
          adjust_count(transaction, start, 1) if stored_hash.nil?
          return nil
        end

        next_pointer = transaction.append(EMPTY_BLOCK)
        previous_position = next_pointer + (nibble(stored_hash, depth + 1) * Slot::SIZE)
        transaction.write_at(previous_position, slot.to_bytes)
        next_pointer
      end
    end

    # A digest-indexed collection that stores original key slots without requiring values.
    class HashSet < HashMap
      # Opens a key-only hash collection, optionally with a stored count.
      # @param cursor [Cursor] view locating this collection or value
      # @param counted [Boolean] whether to store the entry count with the root
      # @return [HashSet]
      # @raise [InvalidValueError] if the cursor holds an incompatible collection tag
      def initialize(cursor, counted: false)
        super(cursor, counted: counted, set: true)
      end
    end

    # A hash map with a stored entry count for constant-time size reads.
    class CountedHashMap < HashMap
      # Opens a hash map whose size is stored in its root.
      # @param cursor [Cursor] view locating this collection or value
      # @return [CountedHashMap]
      # @raise [InvalidValueError] if the cursor holds an incompatible collection tag
      def initialize(cursor)
        super(cursor, counted: true)
      end
    end

    # A hash set with a stored entry count for constant-time size reads.
    class CountedHashSet < HashSet
      # Opens a hash set whose size is stored in its root.
      # @param cursor [Cursor] view locating this collection or value
      # @return [CountedHashSet]
      # @raise [InvalidValueError] if the cursor holds an incompatible collection tag
      def initialize(cursor)
        super(cursor, counted: true)
      end
    end
  end
end
