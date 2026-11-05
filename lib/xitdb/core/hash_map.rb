# frozen_string_literal: true

module XitDB
  module Core
    # A persistent hash trie with optional entry counts.
    class HashMap
      BLOCK_SIZE = 16 * Slot::SIZE
      EMPTY_BLOCK = ("\0".b * BLOCK_SIZE).freeze
      TAGS = %i[hash_map hash_set counted_hash_map counted_hash_set].freeze

      attr_reader :cursor

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

      def self.from_cursor(cursor)
        new(cursor, counted: %i[counted_hash_map counted_hash_set].include?(cursor.slot.tag))
      end

      def get(hash_bytes)
        entry(hash_bytes)&.last
      end

      def key(hash_bytes)
        entry(hash_bytes)&.first
      end

      def include?(hash_bytes)
        !entry(hash_bytes).nil?
      end

      def size
        start = root_pointer
        return 0 unless start

        counted? ? Format.unsigned(read(start, 8)) : each_entry.count
      end

      def put(hash_bytes, key:, value:)
        hash_bytes = validate_hash(hash_bytes)
        validate_slot(key)
        validate_slot(value)
        write_entry(hash_bytes, key: key, value: value)
        self
      end

      def add(hash_bytes, key:)
        hash_bytes = validate_hash(hash_bytes)
        validate_slot(key)
        write_entry(hash_bytes, key: key, value: nil)
        self
      end

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

      def replace_child(hash_bytes, slot, owner: nil, collection: false, propagate: true)
        hash_bytes = validate_hash(hash_bytes)
        validate_slot(slot)
        raise ExpiredViewError, "hash entry was removed" unless include?(hash_bytes)

        write_entry(hash_bytes, key: nil, value: slot, owner: owner, collection: collection, propagate: propagate)
        self
      end

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

      def collection_tag(counted, set)
        if counted
          set ? :counted_hash_set : :counted_hash_map
        else
          set ? :hash_set : :hash_map
        end
      end

      def collapsible?(pointer, start, entries)
        pointer != start + count_bytes && entries.size <= 1 && entries.none? { |slot| slot.tag == :index }
      end

      def collapse_path(transaction, start, path)
        replacement = Slot.new
        path.reverse_each do |old_pointer, block, index|
          block[index * Slot::SIZE, Slot::SIZE] = replacement.to_bytes
          entries = 16.times.map { |i| parse_slot(Format.slice(block, i * Slot::SIZE, Slot::SIZE)) }.reject(&:empty?)
          if collapsible?(old_pointer, start, entries)
            replacement = entries.first || Slot.new
          else
            new_pointer = old_pointer < transaction.mutable_start ? transaction.append(block) : old_pointer
            transaction.write_at(new_pointer, block)
            replacement = Slot.new(tag: :index, value: new_pointer)
          end
        end
      end

      def counted_tag?(tag)
        %i[counted_hash_map counted_hash_set].include?(tag)
      end

      def counted?
        counted_tag?(@tag)
      end

      def count_bytes
        counted? ? 8 : 0
      end

      def hash_size
        cursor.database.header.hash_size
      end

      def validate_hash(hash)
        raise TypeError, "hash must be a String" unless hash.is_a?(String)
        raise ArgumentError, "hash has incorrect width" unless hash.bytesize == hash_size && hash_size.positive?

        hash.b
      end

      def validate_slot(slot)
        raise TypeError, "expected Slot" unless slot.is_a?(Slot)
        raise CorruptionError, "unknown hash record slot tag" unless Slot::TAGS.include?(slot.tag)
        raise InvalidValueError, "index slot is internal to hash branches" if slot.tag == :index
      end

      def nibble(hash, depth)
        raise CorruptionError, "hash trie exceeds hash width" if depth >= hash_size * 2

        byte = hash.getbyte(hash_size - 1 - (depth / 2))
        raise CorruptionError, "hash trie exceeds hash width" unless byte

        (byte >> (depth % 2 * 4)) & 15
      end

      def root_pointer
        slot = cursor.slot
        return nil if slot.tag == :none
        raise InvalidValueError, "slot does not contain the requested hash collection" unless slot.tag == @tag

        read(slot.value, count_bytes + BLOCK_SIZE)
        slot.value
      end

      def read(offset, length)
        cursor.database.read_at(offset, length, bound: cursor.bound)
      end

      def parse_slot(bytes)
        slot = Slot.parse(bytes)
        raise CorruptionError, "unknown hash slot tag" unless Slot::TAGS.include?(slot.tag)

        slot
      end

      def read_record(slot)
        bytes = read(slot.value, hash_size + (Slot::SIZE * 2))
        key = parse_slot(Format.slice(bytes, hash_size, Slot::SIZE))
        value = parse_slot(Format.slice(bytes, hash_size + Slot::SIZE, Slot::SIZE))
        raise CorruptionError, "index slot in hash record" if key.tag == :index || value.tag == :index

        [Format.slice(bytes, 0, hash_size).freeze, key, value]
      end

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

      def writable!
        cursor.slot
        raise ReadOnlyError, "hash collection is read-only" unless cursor.transaction
      end

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

      def writable_root(transaction)
        start = root_pointer
        return transaction.append(("\0".b * count_bytes) + EMPTY_BLOCK) unless start

        bytes = read(start, count_bytes + BLOCK_SIZE)
        start < transaction.mutable_start ? transaction.append(bytes) : start
      end

      def publish(start, propagate: true)
        cursor.update_collection(Slot.new(tag: @tag, value: start), propagate: propagate)
      end

      def adjust_count(transaction, start, delta)
        return unless counted?

        count = Format.unsigned(read(start, 8)) + delta
        Format.integer(count, 0..Format::UINT64_MAX)
        transaction.write_at(start, [count].pack("Q>"))
      end

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

    # A hash trie that stores keys without values.
    class HashSet < HashMap
      def initialize(cursor, counted: false)
        super(cursor, counted: counted, set: true)
      end
    end

    # A hash trie with a stored entry count.
    class CountedHashMap < HashMap
      def initialize(cursor)
        super(cursor, counted: true)
      end
    end

    # A hash set with a stored entry count.
    class CountedHashSet < HashSet
      def initialize(cursor)
        super(cursor, counted: true)
      end
    end
  end
end
