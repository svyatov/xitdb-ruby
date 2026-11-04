# frozen_string_literal: true

module XitDB
  module Core
    class SortedMap
      include Enumerable

      attr_reader :cursor

      def initialize(cursor, set: false)
        @cursor = cursor
        tag = cursor.slot.tag == :none ? (set ? :sorted_set : :sorted_map) : cursor.slot.tag
        raise InvalidValueError, "slot does not contain a sorted collection" unless %i[sorted_map sorted_set].include?(tag)

        @tree = Tree.new(cursor, tag: tag)
      end

      def size
        @tree.size
      end

      def get(key_bytes)
        entry = @tree.find(key_bytes)
        @tree.record(entry).last if entry
      end

      def include?(key_bytes)
        !@tree.find(key_bytes).nil?
      end

      def put(key_bytes, value:)
        replace_child(key_bytes, value)
      end

      def add(key_bytes)
        @tree.store(key_bytes, key_only: true)
        self
      end

      def remove(key_bytes)
        @tree.remove(key_bytes)
      end

      def rank(key_bytes)
        @tree.locate(key_bytes).last
      end

      def at(index)
        entry = @tree.at(index)
        decode(entry) if entry
      end

      def each(&block)
        each_from_index(0, &block)
      end

      def each_from(key_bytes, &block)
        return enum_for(__method__, key_bytes) unless block

        each_from_index(rank(key_bytes), &block)
      end

      def each_from_index(index)
        return enum_for(__method__, index) unless block_given?

        @tree.each_from_index(index) { |entry| yield decode(entry) }
        self
      end

      def cursor_at(key_bytes, create: false)
        slot = get(key_bytes)
        if !slot && create
          add(key_bytes)
          slot = get(key_bytes)
        end
        cursor.hash_child(key_bytes.b.freeze, slot) if slot
      end

      def replace_child(key_bytes, slot, **options)
        @tree.store(key_bytes, value: slot, **options)
        self
      end

      private

      def decode(entry)
        key, value = @tree.record(entry)
        [cursor.database.read_bytes(key, bound: cursor.bound).bytes, value]
      end

      class Tree < BTree
        BRANCH_SIZE = 418
        Node = Struct.new(:kind, :slots, :counts, :separators) do
          def size
            kind.zero? ? slots.size : counts.sum
          end
        end

        def record(entry)
          return [entry, Slot.new] if %i[bytes short_bytes].include?(entry.tag)
          unless %i[kv_pair sorted_kv_pair].include?(entry.tag)
            raise CorruptionError, "invalid sorted entry"
          end

          offset = entry.value + (entry.tag == :kv_pair ? cursor.database.header.hash_size : 0)
          bytes = read(offset, 18)
          key = Slot.parse(bytes.byteslice(0, 9))
          value = Slot.parse(bytes.byteslice(9, 9))
          unless %i[bytes short_bytes].include?(key.tag) && Slot::TAGS.include?(value.tag) && value.tag != :index
            raise CorruptionError, "invalid sorted record slots"
          end

          [key, value]
        end

        def find(key)
          _path, node, index, found, = locate(key)
          node.slots[index] if found
        end

        def locate(key)
          raise TypeError, "sorted key must be a String" unless key.is_a?(String)

          key = key.b
          count, pointer = header
          path = []
          seen = {}
          rank = 0
          loop do
            raise CorruptionError, "cyclic sorted branch" if seen[pointer]

            seen[pointer] = true
            node = pointer ? read_node(pointer, count) : Node.new(0, [], [], [])
            if node.kind.zero?
              index = lower_bound(node.slots.size) { |i| key_bytes(record(node.slots[i]).first) >= key }
              found = index < node.slots.size && key_bytes(record(node.slots[index]).first) == key
              return [path, node, index, found, rank + index]
            end
            index = lower_bound(node.slots.size - 1) { |i| key_bytes(node.separators[i + 1]) > key }
            path << [pointer, node, index]
            rank += node.counts.first(index).sum
            pointer = node.slots[index].value
            count = node.counts[index]
          end
        end

        def store(key, value: nil, key_only: false, owner: nil, collection: false, propagate: true)
          validate_slot(value) unless key_only
          mutate do |tx|
            count, pointer = header
            path, node, index, found, = locate(key)
            next if found && key_only
            raise RangeError, "sorted size exceeds unsigned 64-bit range" if !found && count == Format::UINT64_MAX

            key_slot = found ? record(node.slots[index]).first : cursor.database.bytes(key)
            entry = key_only ? key_slot : Slot.new(tag: :sorted_kv_pair, value: tx.append(key_slot.to_bytes + value.to_bytes))
            found ? node.slots[index] = entry : node.slots.insert(index, entry)
            result = split_node(tx, node, pointer_for(path, pointer))
            path.reverse_each do |parent_pointer, parent, child_index|
              parent.slots[child_index, 1] = result.map { |ptr, _, _| Slot.new(tag: :index, value: ptr) }
              parent.counts[child_index, 1] = result.map { |_, size, _| size }
              parent.separators.insert(child_index + 1, result.last.last) if result.size == 2
              result = split_node(tx, parent, parent_pointer)
            end
            root = if result.size == 1
              result.first.first
            else
              write_node(tx, Node.new(1, result.map { |ptr, _, _| Slot.new(tag: :index, value: ptr) },
                                     result.map { |_, size, _| size }, [Slot.new, result.last.last]))
            end
            publish(tx, count + (found ? 0 : 1), root, propagate: propagate)
            cursor.invalidate_children(index: key.b, except: owner) unless collection || key_only
          end
          self
        end

        def remove(key)
          mutate do |tx|
            count, pointer = header
            path, node, index, found, = locate(key)
            next false unless found

            node.slots.delete_at(index)
            child_pointer = write_node(tx, node, pointer_for(path, pointer))
            path.reverse_each do |parent_pointer, parent, child_index|
              parent.slots[child_index] = Slot.new(tag: :index, value: child_pointer)
              parent.counts[child_index] -= 1
              child_pointer = write_node(tx, parent, parent_pointer)
            end
            publish(tx, count - 1, child_pointer)
            cursor.invalidate_children(index: key.b)
            true
          end
        end

        private

        def lower_bound(size)
          left = 0
          right = size
          while left < right
            middle = (left + right) / 2
            yield(middle) ? right = middle : left = middle + 1
          end
          left
        end

        def key_bytes(slot)
          raise CorruptionError, "invalid sorted key" unless %i[bytes short_bytes].include?(slot.tag)

          cursor.database.read_bytes(slot, bound: cursor.bound).bytes
        end

        def read_node(pointer, expected, bound: cursor.bound)
          kind, num = read(pointer, 2, bound: bound).unpack("CC")
          unless [0, 1].include?(kind) && num <= CAPACITY && (kind.zero? || num.positive?)
            raise CorruptionError, "invalid sorted node header"
          end
          bytes = read(pointer, kind.zero? ? LEAF_SIZE : BRANCH_SIZE, bound: bound)
          slots = num.times.map { |i| Slot.parse(bytes.byteslice(2 + i * 9, 9)) }
          separators = kind.zero? ? [] : num.times.map { |i| Slot.parse(bytes.byteslice(LEAF_SIZE + i * 9, 9)) }
          counts = kind.zero? ? [] : bytes.byteslice(290, 128).unpack("Q>*").first(num)
          valid = if kind.zero?
            slots.all? { |slot| %i[bytes short_bytes kv_pair sorted_kv_pair].include?(slot.tag) }
          else
            slots.all? { |slot| slot.tag == :index } && separators.drop(1).all? { |slot| %i[bytes short_bytes].include?(slot.tag) }
          end
          node = Node.new(kind, slots, counts, separators)
          raise CorruptionError, "invalid sorted node" unless valid && node.size == expected

          node
        end

        def write_node(tx, node, old_pointer = nil)
          bytes = [node.kind, node.slots.size].pack("CC")
          bytes << padded_slots(node.slots)
          unless node.kind.zero?
            bytes << padded_slots(node.separators)
            bytes << (node.counts + [0] * (CAPACITY - node.counts.size)).pack("Q>*")
          end
          if old_pointer && old_pointer >= tx.mutable_start
            tx.write_at(old_pointer, bytes)
            old_pointer
          else
            tx.append(bytes)
          end
        end

        def padded_slots(slots)
          slots.map(&:to_bytes).join + "\0".b * ((CAPACITY - slots.size) * 9)
        end

        def split_node(tx, node, old_pointer)
          return [[write_node(tx, node, old_pointer), node.size, nil]] if node.slots.size <= CAPACITY

          separator = node.kind.zero? ? record(node.slots[SPLIT_COUNT]).first : node.separators[SPLIT_COUNT]
          left = Node.new(node.kind, node.slots.first(SPLIT_COUNT), node.counts.first(SPLIT_COUNT), node.separators.first(SPLIT_COUNT))
          right = Node.new(node.kind, node.slots.drop(SPLIT_COUNT), node.counts.drop(SPLIT_COUNT), node.separators.drop(SPLIT_COUNT))
          [[write_node(tx, left, old_pointer), left.size, nil], [write_node(tx, right), right.size, separator]]
        end
      end
      private_constant :Tree
    end

    class SortedSet < SortedMap
      def initialize(cursor)
        super(cursor, set: true)
      end
    end
  end
end
