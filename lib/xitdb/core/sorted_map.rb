# frozen_string_literal: true

module XitDB
  module Core
    # A byte-ordered map backed by a counted B-tree.
    class SortedMap
      include Enumerable

      attr_reader :cursor

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
        return enum_for(:each) unless block

        each_from_index(0, &block)
      end

      def each_from(key_bytes, &block)
        return enum_for(:each_from, key_bytes) unless block

        each_from_index(rank(key_bytes), &block)
      end

      def each_from_index(index)
        return enum_for(:each_from_index, index) unless block_given?

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

      def replace_child(key_bytes, slot, **)
        @tree.store(key_bytes, value: slot, **)
        self
      end

      private

      def decode(entry)
        key, value = @tree.record(entry)
        [cursor.database.read_bytes(key, bound: cursor.bound).bytes, value]
      end

      # Maintains sorted records and branch separators.
      class Tree < BTree
        BRANCH_SIZE = 418
        # A mutable sorted node and its separators.
        class Node
          attr_accessor :kind, :slots, :counts, :separators

          def initialize(kind, slots, counts, separators)
            @kind = kind
            @slots = slots
            @counts = counts
            @separators = separators
          end

          def size
            kind.zero? ? slots.size : counts.sum
          end
        end

        def record(entry)
          return [entry, Slot.new] if %i[bytes short_bytes].include?(entry.tag)
          raise CorruptionError, "invalid sorted entry" unless %i[kv_pair sorted_kv_pair].include?(entry.tag)

          offset = entry.value + (entry.tag == :kv_pair ? cursor.database.header.hash_size : 0)
          bytes = read(offset, 18)
          key = Slot.parse(Format.slice(bytes, 0, 9))
          value = Slot.parse(Format.slice(bytes, 9, 9))
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
          # @type var path: sorted_path
          path = []
          # @type var seen: Hash[Integer?, bool]
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
            raise CorruptionError, "missing sorted branch pointer" unless pointer

            path << [pointer, node, index]
            rank += node.counts.first(index).sum
            pointer = node.slots[index].value
            count = node.counts[index]
          end
        end

        def store(key, value: nil, key_only: false, owner: nil, collection: false, propagate: true)
          unless key_only
            raise TypeError, "expected Slot" unless value

            validate_slot(value)
          end
          mutate do |transaction|
            count, pointer = header
            path, node, index, found, = locate(key)
            next if found && key_only
            raise RangeError, "sorted size exceeds unsigned 64-bit range" if !found && count == Format::UINT64_MAX

            store_leaf(transaction, key, node, index, found, key_only, value)
            root = write_path(transaction, path, node, pointer_for(path, pointer))
            publish(transaction, count + (found ? 0 : 1), root, propagate: propagate)
            cursor.invalidate_children(index: key.b, except: owner) unless collection || key_only
          end
          self
        end

        def remove(key)
          mutate do |transaction|
            count, pointer = header
            path, node, index, found, = locate(key)
            next false unless found

            node.slots.delete_at(index)
            old_pointer = pointer_for(path, pointer)
            path.reverse_each do |parent_pointer, parent, child_index|
              if node.slots.empty?
                parent.slots.delete_at(child_index)
                parent.counts.delete_at(child_index)
                parent.separators.delete_at(child_index)
                parent.separators[0] = Slot.new unless parent.separators.empty?
              else
                parent.slots[child_index] = Slot.new(tag: :index, value: write_node(transaction, node, old_pointer))
                parent.counts[child_index] = node.size
              end
              node = parent
              old_pointer = parent_pointer
            end
            root_pointer = collapse_sorted_root(transaction, node, old_pointer, count - 1)
            publish(transaction, count - 1, root_pointer)
            cursor.invalidate_children(index: key.b)
            true
          end
        end

        private

        def store_leaf(transaction, key, node, index, found, key_only, value)
          key_slot = found ? record(node.slots[index]).first : cursor.database.bytes(key)
          entry = if key_only
                    key_slot
                  else
                    raise TypeError, "expected Slot" unless value

                    Slot.new(tag: :sorted_kv_pair, value: transaction.append(key_slot.to_bytes + value.to_bytes))
                  end
          found ? node.slots[index] = entry : node.slots.insert(index, entry)
        end

        def write_path(transaction, path, node, pointer)
          result = split_node(transaction, node, pointer)
          path.reverse_each do |parent_pointer, parent, child_index|
            parent.slots[child_index, 1] = result.map { |ptr, _, _| Slot.new(tag: :index, value: ptr) }
            parent.counts[child_index, 1] = result.map { |_, size, _| size }
            parent.separators.insert(child_index + 1, split_separator(result)) if result.size == 2
            result = split_node(transaction, parent, parent_pointer)
          end
          return result.first.first if result.size == 1

          write_node(transaction, Node.new(1, result.map { |ptr, _, _| Slot.new(tag: :index, value: ptr) },
                                           result.map { |_, size, _| size }, [Slot.new, split_separator(result)]))
        end

        def collapse_sorted_root(transaction, node, old_pointer, count)
          unless node.kind == 1 && node.slots.size == 1
            node = Node.new(0, [], [], []) if node.slots.empty?
            return write_node(transaction, node, old_pointer)
          end

          pointer = node.slots.first.value
          # @type var seen: Hash[Integer, bool]
          seen = {}
          loop do
            raise CorruptionError, "cyclic sorted branch" if seen[pointer]

            seen[pointer] = true
            child = read_node(pointer, count)
            return pointer unless child.kind == 1 && child.slots.size == 1

            pointer = child.slots.first.value
          end
        end

        def split_separator(result)
          result.last.last || raise(CorruptionError, "missing sorted split separator")
        end

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
          kind, num = Format.pair(read(pointer, 2, bound: bound), "CC")
          validate_header(kind, num)

          bytes = read(pointer, kind.zero? ? LEAF_SIZE : BRANCH_SIZE, bound: bound)
          slots = Array.new(num) { |i| Slot.parse(Format.slice(bytes, 2 + (i * 9), 9)) }
          # @type var separators: Array[Slot]
          separators = kind.zero? ? [] : Array.new(num) { |i| Slot.parse(Format.slice(bytes, LEAF_SIZE + (i * 9), 9)) }
          # @type var counts: Array[Integer]
          counts = kind.zero? ? [] : Format.integers(Format.slice(bytes, 290, 128), "Q>*").first(num)
          node = Node.new(kind, slots, counts, separators)
          raise CorruptionError, "invalid sorted node" unless valid_node?(node) && node.size == expected

          node
        end

        def validate_header(kind, count)
          return if [0, 1].include?(kind) && count <= CAPACITY && (kind.zero? || count.positive?)

          raise CorruptionError, "invalid sorted node header"
        end

        def valid_node?(node)
          if node.kind.zero?
            node.slots.all? { |slot| %i[bytes short_bytes kv_pair sorted_kv_pair].include?(slot.tag) }
          else
            node.slots.all? { |slot| slot.tag == :index } && node.separators.drop(1).all? do |slot|
              %i[bytes short_bytes].include?(slot.tag)
            end
          end
        end

        def write_node(transaction, node, old_pointer = nil)
          bytes = [node.kind, node.slots.size].pack("CC")
          bytes << padded_slots(node.slots)
          unless node.kind.zero?
            raise CorruptionError, "invalid sorted branch" unless node.is_a?(Node)

            bytes << padded_slots(node.separators)
            bytes << (node.counts + ([0] * (CAPACITY - node.counts.size))).pack("Q>*")
          end
          if old_pointer && old_pointer >= transaction.mutable_start
            transaction.write_at(old_pointer, bytes)
            old_pointer
          else
            transaction.append(bytes)
          end
        end

        def padded_slots(slots)
          slots.map(&:to_bytes).join + ("\0".b * ((CAPACITY - slots.size) * 9))
        end

        def split_node(transaction, node, old_pointer)
          return [[write_node(transaction, node, old_pointer), node.size, nil]] if node.slots.size <= CAPACITY

          separator = node.kind.zero? ? record(node.slots[SPLIT_COUNT]).first : node.separators[SPLIT_COUNT]
          left = Node.new(node.kind, node.slots.first(SPLIT_COUNT), node.counts.first(SPLIT_COUNT),
                          node.separators.first(SPLIT_COUNT))
          right = Node.new(node.kind, node.slots.drop(SPLIT_COUNT), node.counts.drop(SPLIT_COUNT),
                           node.separators.drop(SPLIT_COUNT))
          [[write_node(transaction, left, old_pointer), left.size, nil],
           [write_node(transaction, right), right.size, separator]]
        end
      end
      private_constant :Tree
    end

    # A byte-ordered collection of keys.
    class SortedSet < SortedMap
      def initialize(cursor)
        super(cursor, set: true)
      end
    end
  end
end
