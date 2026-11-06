# frozen_string_literal: true

module XitDB
  module Core
    class SortedMap
      # Sorted record storage and separator-key maintenance for the counted tree.
      # @api private
      class Tree < BTree
        # Bytes in a sorted branch containing slots, separator keys, and subtree counts.
        BRANCH_SIZE = 418
        # A mutable in-memory node used while rebuilding a stored tree path.
        # @api private
        class Node
          # @!attribute [rw] kind
          #   Zero for a leaf, or one for a branch.
          #   @return [Integer]
          # @!attribute [rw] slots
          #   Leaf entries or branch pointer slots.
          #   @return [Array<Slot>]
          # @!attribute [rw] counts
          #   Number of elements under each branch pointer.
          #   @return [Array<Integer>]
          # @!attribute [rw] separators
          #   Key slots that separate adjacent child ranges.
          #   @return [Array<Slot>]
          attr_accessor :kind, :slots, :counts, :separators

          # Builds a sorted leaf or branch with separator keys.
          # @param kind [Integer] zero for a leaf, or one for a branch
          # @param slots [Array<Slot>] leaf values or branch pointer slots
          # @param counts [Array<Integer>] element count beneath each branch pointer
          # @param separators [Array<Slot>] keys separating child ranges
          # @return [Node]
          def initialize(kind, slots, counts, separators)
            @kind = kind
            @slots = slots
            @counts = counts
            @separators = separators
          end

          # Counts leaf entries or sums child subtree counts.
          # @return [Integer]
          def size
            kind.zero? ? slots.size : counts.sum
          end
        end

        # Decodes a key-only slot or a record containing key and value slots.
        # @param entry [Slot] stored sorted entry descriptor
        # @return [Array(Slot, Slot)]
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

        # Finds the stored entry for an exact binary key.
        # @param key [String] binary key compared in byte order
        # @return [Slot, nil]
        def find(key)
          _path, node, index, found, = locate(key)
          node.slots[index] if found
        end

        # Finds a key's leaf position, presence, rank, and ancestor path.
        # @param key [String] binary key compared in byte order
        # @return [Array]
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

        # Inserts a key-only entry or replaces its value, copying the search path.
        # @param key [String] binary key compared in byte order
        # @param value [Slot, nil] value slot; nil is permitted when key_only is true
        # @param key_only [Boolean] whether to add a key without storing a value
        # @param owner [Cursor, nil] child view to preserve during replacement
        # @param collection [Boolean] whether this is an internal copied collection update
        # @param propagate [Boolean] whether to update parent collection paths immediately
        # @return [self]
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

        # Removes a key and collapses redundant root levels.
        # @param key [String] binary key compared in byte order
        # @return [Boolean]
        # @raise [ReadOnlyError] if the collection has no writable transaction
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

        # Writes a key-only slot or a separate key/value record into a leaf.
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

        # Rebuilds ancestors and separators after a leaf insertion or replacement.
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

        # Removes redundant single-child roots while rejecting cycles.
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

        # Retrieves the key separating two nodes after a split.
        def split_separator(result)
          result.last.last || raise(CorruptionError, "missing sorted split separator")
        end

        # Finds the first index whose yielded comparison is true using binary search.
        def lower_bound(size)
          left = 0
          right = size
          while left < right
            middle = (left + right) / 2
            yield(middle) ? right = middle : left = middle + 1
          end
          left
        end

        # Reads and validates bytes from a sorted key slot.
        def key_bytes(slot)
          raise CorruptionError, "invalid sorted key" unless %i[bytes short_bytes].include?(slot.tag)

          cursor.database.read_bytes(slot, bound: cursor.bound).bytes
        end

        # Decodes slots, separators, and counts, then checks expected subtree size.
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

        # Checks the kind and occupied slot count of a sorted node.
        def validate_header(kind, count)
          return if [0, 1].include?(kind) && count <= CAPACITY && (kind.zero? || count.positive?)

          raise CorruptionError, "invalid sorted node header"
        end

        # Checks that leaf entries and branch separators use permitted tags.
        def valid_node?(node)
          if node.kind.zero?
            tags = %i[bytes short_bytes kv_pair sorted_kv_pair]
            node.slots.all? { |slot| tags.include?(slot.tag) }
          else
            tags = %i[bytes short_bytes]
            node.slots.all? { |slot| slot.tag == :index } && node.separators.drop(1).all? do |slot|
              tags.include?(slot.tag)
            end
          end
        end

        # Encodes a sorted node, copying storage below the writable boundary.
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

        # Encodes occupied slots and fills unused positions with zero bytes.
        def padded_slots(slots)
          slots.map(&:to_bytes).join + ("\0".b * ((CAPACITY - slots.size) * 9))
        end

        # Splits an overflowing sorted node and retains the new boundary key.
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
  end
end
