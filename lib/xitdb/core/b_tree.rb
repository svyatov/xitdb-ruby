# frozen_string_literal: true

module XitDB
  module Core
    # Counted tree algorithms used by linked lists and sorted collections.
    #
    # Leaf nodes hold slots. Branch nodes hold child pointers and the number of elements below each pointer.
    # @api private
    class BTree
      # Bytes storing the element count and root node offset.
      HEADER_SIZE = 16
      # Maximum occupied slots in one leaf or branch node.
      CAPACITY = 16
      # Number of slots placed in the left half when a full node splits.
      SPLIT_COUNT = 8
      # Bytes in an encoded leaf, including its two-byte node header.
      LEAF_SIZE = 146
      # Bytes in an encoded branch, including sixteen unsigned subtree counts.
      BRANCH_SIZE = 274
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
        attr_accessor :kind, :slots, :counts

        # Builds a mutable leaf or branch during a copied tree update.
        # @param kind [Integer] zero for a leaf, or one for a branch
        # @param slots [Array<Slot>] leaf values or branch pointer slots
        # @param counts [Array<Integer>] element count beneath each branch pointer
        # @return [Node]
        def initialize(kind, slots, counts)
          @kind = kind
          @slots = slots
          @counts = counts
        end

        # Counts leaf slots or sums the element counts of child branches.
        # @return [Integer]
        def size
          kind.zero? ? slots.size : counts.sum
        end
      end
      private_constant :Node

      # View locating this collection.
      # @return [Cursor]
      attr_reader :cursor

      # Opens a counted tree and initializes an empty writable cursor when needed.
      # @param cursor [Cursor] view locating this collection or value
      # @param tag [Symbol, Integer] storage type tag
      # @return [BTree]
      # @raise [InvalidValueError] if the cursor holds an incompatible collection tag
      def initialize(cursor, tag: :linked_array_list)
        @cursor = cursor
        @tag = tag
        unless [:none, @tag].include?(cursor.slot.tag)
          raise InvalidValueError, "slot does not contain a linked array list"
        end

        return unless cursor.slot.tag == :none && cursor.transaction

        mutate do |transaction|
          pointer = write_node(transaction, Node.new(0, [], []))
          publish(transaction, 0, pointer)
        end
      end

      # Returns the total number of elements below the root.
      # @return [Integer]
      def size
        header.first
      end

      # Reads an element by index, counting negative indexes from the end.
      # @param index [Integer] zero-based element index; negative indexes count from the end
      # @return [Slot, nil]
      def at(index)
        count, pointer = header
        rank = resolve_index(index, count)
        return nil unless rank

        _path, node, rank = descend(pointer, rank, count)
        node.slots.fetch(rank)
      end

      # Inserts a slot from index zero through size and shifts later elements.
      # @param index [Integer] insertion position from zero through size; negative indexes are rejected
      # @param slot [Slot] stored value or record descriptor
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      def insert(index, slot)
        validate_slot!(slot)
        count, pointer = header
        ensure_integer_index!(index)
        raise IndexError, "array index outside list" unless index.between?(0, count)
        raise RangeError, "array size exceeds unsigned 64-bit range" if count == Format::UINT64_MAX

        mutate do |transaction|
          path, node, rank = descend(pointer, index, count, insertion: true)
          node.slots.insert(rank, slot)
          result = write_split(transaction, node, pointer_for(path, pointer))
          path.reverse_each do |parent_pointer, parent, child_index|
            parent.slots[child_index, 1] = result.map { |ptr, _| Slot.new(tag: :index, value: ptr) }
            parent.counts[child_index, 1] = result.map(&:last)
            result = write_split(transaction, parent, parent_pointer)
          end
          root_pointer = if result.size == 1
                           result.first.first
                         else
                           write_node(transaction, Node.new(1, result.map do |ptr, _|
                             Slot.new(tag: :index, value: ptr)
                           end, result.map(&:last)))
                         end
          publish(transaction, count + 1, root_pointer)
          cursor.invalidate_children(from: index)
        end
        self
      end

      # Replaces an existing element while preserving optional child ownership.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @param slot [Slot] stored value or record descriptor
      # @param owner [Cursor, nil] child view to preserve during replacement
      # @param collection [Boolean] whether this is an internal copied collection update
      # @param propagate [Boolean] whether to update parent collection paths immediately
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      def replace(index, slot, owner: nil, collection: false, propagate: true)
        validate_slot!(slot)
        count, pointer = header
        rank = resolve_index(index, count)
        raise IndexError, "array index outside list" unless rank

        mutate do |transaction|
          path, node, rank = descend(pointer, rank, count)
          node.slots[rank] = slot
          child_pointer = write_node(transaction, node, pointer_for(path, pointer))
          path.reverse_each do |parent_pointer, parent, child_index|
            parent.slots[child_index] = Slot.new(tag: :index, value: child_pointer)
            child_pointer = write_node(transaction, parent, parent_pointer)
          end
          publish(transaction, count, child_pointer, propagate: propagate)
          cursor.invalidate_children(index: resolve_index(index, count), except: owner) unless collection
        end
        self
      end

      # Removes the indexed slot and joins small neighboring nodes when possible.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [Slot, nil]
      def delete_at(index)
        count, pointer = header
        rank = resolve_index(index, count)
        return nil unless rank

        mutate do |transaction|
          path, node, offset = descend(pointer, rank, count)
          removed = node.slots.delete_at(offset)
          old_pointer = pointer_for(path, pointer)
          path.reverse_each do |parent_pointer, parent, child_index|
            rebalance_child(transaction, node, parent, child_index, old_pointer)
            node = parent
            old_pointer = parent_pointer
          end
          root_pointer = collapse_root(transaction, node, old_pointer, count - 1)
          publish(transaction, count - 1, root_pointer)
          cursor.invalidate_children(from: rank)
          removed
        end
      end

      # Creates detached trees that share unchanged nodes around the split index.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [Array<BTree>]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      def split(index)
        count, pointer = header
        ensure_integer_index!(index)
        index += count if index.negative?
        raise IndexError, "array split outside list" unless index.between?(0, count)

        mutate do |transaction|
          split_root(transaction, [pointer, count, cursor.bound], index).map { |ref| detached(transaction, ref) }
        end
      end

      # Creates a detached tree for a range without replacing the source root.
      # @param start [Integer] first selected index; negative indexes count from the end
      # @param length [Integer] number of elements in the selected range
      # @return [BTree]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      def slice(start, length)
        count, pointer = header
        ensure_integer_index!(start)
        ensure_integer_index!(length)
        start += count if start.negative?
        unless start.between?(0, count) && length >= 0 && length <= count - start
          raise IndexError, "array slice outside list"
        end

        mutate do |transaction|
          _left, tail = split_root(transaction, [pointer, count, cursor.bound], start)
          selected, _right = split_root(transaction, tail, length)
          detached(transaction, selected)
        end
      end

      # Creates a detached tree joining two lists from the same database.
      # @param other [BTree] list from the same database to append to this list
      # @return [BTree]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [ForeignValueError] if the other list belongs to another database
      def concat(other)
        raise TypeError, "expected BTree" unless other.is_a?(BTree)
        unless cursor.database.equal?(other.cursor.database)
          raise ForeignValueError, "cannot share linked arrays across databases"
        end

        count, pointer = header
        other_count, other_pointer = other.send(:header)
        raise RangeError, "array size exceeds unsigned 64-bit range" if count + other_count > Format::UINT64_MAX

        mutate do |transaction|
          ref = join_roots(transaction, [pointer, count, cursor.bound],
                           [other_pointer, other_count, other.cursor.bound])
          detached(transaction, ref)
        end
      end

      # Walks leaves in order from an index, continuing through recorded ancestor paths.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [self, Enumerator<Slot>]
      # @yield [slot] receives each visible element
      # @yieldparam slot [Slot] stored element
      # @yieldreturn [Object] ignored
      # @note Without a block, returns an Enumerator.
      def each_from_index(index, &block)
        return enum_for(:each_from_index, index) unless block_given?

        count, pointer = header
        ensure_integer_index!(index)
        index += count if index.negative?
        return self unless index >= 0 && index < count

        path, node, rank = descend(pointer, index, count)
        loop do
          node.slots.drop(rank).each(&block)
          # @type var frame: [Integer, node, Integer]?
          frame = next_frame(path)
          break unless frame

          parent_pointer, parent, child_index = frame
          child_index += 1
          path << [parent_pointer, parent, child_index]
          subpath, node, rank = descend(parent.slots[child_index].value, 0, parent.counts[child_index],
                                        ancestors: path.map(&:first))
          path.concat(subpath)
        end
        self
      end

      private

      # Pops exhausted traversal frames until a following sibling is available.
      def next_frame(path)
        until path.empty?
          candidate = path.pop || raise(CorruptionError, "missing B-tree path")
          return candidate if candidate[2] + 1 < candidate[1].slots.size
        end
        nil
      end

      # Removes an empty child or merges it with a neighbor when both fit.
      def rebalance_child(transaction, node, parent, index, old_pointer)
        if node.slots.empty?
          parent.slots.delete_at(index)
          parent.counts.delete_at(index)
        else
          node, index = merge_neighbor(node, parent, index) if node.slots.size < SPLIT_COUNT && parent.slots.size > 1
          parent.slots[index] = Slot.new(tag: :index, value: write_node(transaction, node, old_pointer))
          parent.counts[index] = node.size
        end
      end

      # Selects an adjacent node and returns their merged node and replacement index.
      def merge_neighbor(node, parent, index)
        first = index + 1 < parent.slots.size ? index : index - 1
        neighbor_index = first == index ? first + 1 : first
        neighbor = read_node(parent.slots[neighbor_index].value, parent.counts[neighbor_index])
        raise CorruptionError, "unequal B-tree child heights" unless neighbor.kind == node.kind
        return [node, index] if node.slots.size + neighbor.slots.size > CAPACITY

        node = first == index ? merge_nodes(node, neighbor) : merge_nodes(neighbor, node)
        parent.slots.delete_at(first + 1)
        parent.counts.delete_at(first + 1)
        [node, first]
      end

      # Removes redundant single-child root levels after deletion.
      def collapse_root(transaction, node, old_pointer, count)
        unless node.kind == 1 && node.slots.size == 1
          node = Node.new(0, [], []) if node.slots.empty?
          return write_node(transaction, node, old_pointer)
        end

        pointer = node.slots.first.value
        # @type var seen: Hash[Integer, bool]
        seen = {}
        loop do
          raise CorruptionError, "cyclic B-tree branch" if seen[pointer]

          seen[pointer] = true
          child = read_node(pointer, count)
          return pointer unless child.kind == 1 && child.slots.size == 1

          pointer = child.slots.first.value
        end
      end

      # Checks that an index is an Integer.
      def ensure_integer_index!(index)
        raise TypeError, "array index must be an Integer" unless index.is_a?(Integer)
      end

      # Normalizes a negative index and rejects positions outside the tree.
      def resolve_index(index, count)
        ensure_integer_index!(index)
        index += count if index.negative?
        index if index >= 0 && index < count
      end

      # Reads a range inside the supplied or current cursor boundary.
      def read(offset, length, bound: cursor.bound)
        cursor.database.read_at(offset, length, bound: bound)
      end

      # Reads root count and pointer, treating an empty slot as an empty tree.
      def header
        slot = cursor.slot
        return [0, nil] if slot.tag == :none
        raise InvalidValueError, "slot does not contain the expected B-tree type" unless slot.tag == @tag

        Format.pair(read(slot.value, HEADER_SIZE), "Q>Q>")
      end

      # Decodes a leaf or branch and checks its expected subtree count.
      def read_node(pointer, expected, bound: cursor.bound)
        kind, num = read_node_header(pointer, bound)
        bytes = read(pointer, kind.zero? ? LEAF_SIZE : BRANCH_SIZE, bound: bound)
        slots = node_slots(bytes, 2, CAPACITY).first(num)
        # @type var counts: Array[Integer]
        counts = kind.zero? ? [] : Format.integers(Format.slice(bytes, LEAF_SIZE, 128), "Q>*").first(num)
        node = Node.new(kind, slots, counts)
        validate_node!(node, expected)
        node
      end

      # Validates the node kind and number of occupied slots.
      def read_node_header(pointer, bound)
        kind, num = Format.pair(read(pointer, 2, bound: bound), "CC")
        unless [0, 1].include?(kind) && num <= CAPACITY && (kind.zero? || num.positive?)
          raise CorruptionError, "invalid B-tree node header"
        end

        [kind, num]
      end

      # Decodes and validates a sequence of packed slots.
      def node_slots(bytes, start, count)
        Array.new(count) do |index|
          slot = Slot.parse(Format.slice(bytes, start + (index * Slot::SIZE), Slot::SIZE))
          raise CorruptionError, "unknown B-tree slot tag" unless Slot::TAGS.include?(slot.tag)

          slot
        end
      end

      # Checks slot roles and the expected element count below a node.
      def validate_node!(node, expected)
        case node.kind
        when 1 then validate_branch!(node)
        when 0 then validate_leaf!(node)
        end

        raise CorruptionError, "invalid B-tree subtree count" unless node.size == expected
      end

      # Requires branch pointers and positive child counts.
      def validate_branch!(node)
        return unless node.slots.any? { |slot| slot.tag != :index } || node.counts.any?(&:zero?)

        raise CorruptionError, "invalid B-tree branch"
      end

      # Rejects branch pointers inside leaf data.
      def validate_leaf!(node)
        raise CorruptionError, "index slot in B-tree leaf" if node.slots.any? { |slot| slot.tag == :index }
      end

      # Follows subtree counts to an indexed leaf, recording ancestors and rejecting cycles.
      def descend(pointer, rank, expected, insertion: false, ancestors: [])
        return [[], Node.new(0, [], []), 0] unless pointer

        # @type var path: path
        path = []
        seen = ancestors.to_h { |ptr| [ptr, true] }
        loop do
          raise CorruptionError, "cyclic B-tree branch" if seen[pointer]

          seen[pointer] = true
          node = read_node(pointer, expected)
          return [path, node, rank] if node.kind.zero?

          i = 0
          while i + 1 < node.slots.size && (insertion ? rank > node.counts[i] : rank >= node.counts[i])
            rank -= node.counts[i]
            i += 1
          end
          path << [pointer, node, i]
          pointer = node.slots[i].value
          expected = node.counts[i]
        end
      end

      # Finds the current leaf pointer from a recorded path or root.
      def pointer_for(path, root_pointer)
        path.empty? ? root_pointer : path.last[1].slots[path.last[2]].value
      end

      # Rejects unknown tags and internal branch slots as user elements.
      def validate_slot!(slot)
        raise TypeError, "expected Slot" unless slot.is_a?(Slot)
        raise CorruptionError, "unknown slot tag" unless Slot::TAGS.include?(slot.tag)
        raise InvalidValueError, "index slot is internal to B-tree branches" if slot.tag == :index
      end

      # Runs a mutation with rollback of bytes and cursors on any exception.
      def mutate
        cursor.slot
        transaction = cursor.transaction
        raise ReadOnlyError, "linked array list is read-only" unless transaction

        checkpoint = transaction.checkpoint
        begin
          result = yield transaction
        rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
          transaction.restore(checkpoint)
          raise
        else
          transaction.release_checkpoint(checkpoint)
          result
        end
      end

      # Reads a shared subtree using its retained source boundary.
      def node_for(ref)
        pointer = ref[0]
        raise CorruptionError, "missing B-tree pointer" unless pointer

        read_node(pointer, ref[1], bound: ref[2] || cursor.bound)
      end

      # Builds a child reference retaining the parent's read boundary.
      def child_ref(ref, node, index)
        [node.slots[index].value, node.counts[index], ref[2]]
      end

      # Combines slots and counts from nodes at the same level.
      def merge_nodes(left, right)
        raise CorruptionError, "unequal B-tree node kinds" unless left.kind == right.kind

        Node.new(left.kind, left.slots + right.slots, left.counts + right.counts)
      end

      # Writes one node or divides an oversized node into two references.
      def assemble(transaction, node)
        if node.slots.size <= CAPACITY
          [[write_node(transaction, node), node.size, nil]]
        else
          middle = node.slots.size / 2
          [Node.new(node.kind, node.slots.first(middle), node.counts.first(middle)),
           Node.new(node.kind, node.slots.drop(middle), node.counts.drop(middle))].map do |half|
            [write_node(transaction, half), half.size, nil]
          end
        end
      end

      # Builds a branch from subtree pointers and counts.
      def branch(refs)
        slots = refs.map do |ref|
          pointer = ref[0]
          raise CorruptionError, "missing B-tree pointer" unless pointer

          Slot.new(tag: :index, value: pointer)
        end
        Node.new(1, slots, refs.map { |ref| ref[1] })
      end

      # Counts branch levels while rejecting cyclic child pointers.
      def height(ref)
        levels = 0
        # @type var seen: Hash[Integer?, bool]
        seen = {}
        loop do
          raise CorruptionError, "cyclic B-tree branch" if seen[ref[0]]

          seen[ref[0]] = true
          node = node_for(ref)
          return levels if node.kind.zero?

          ref = child_ref(ref, node, 0)
          levels += 1
        end
      end

      # Aligns tree heights and joins boundary paths while sharing other subtrees.
      def join_roots(transaction, left, right)
        return right if left[1].zero?
        return left if right[1].zero?

        left_height = height(left)
        right_height = height(right)
        # @type var node: node
        # @type var path: Array[[ref, node, Integer]]
        path = []
        while left_height > right_height
          node = node_for(left)
          index = node.slots.size - 1
          path << [left, node, index]
          left = child_ref(left, node, index)
          left_height -= 1
        end
        while right_height > left_height
          node = node_for(right)
          path << [right, node, 0]
          right = child_ref(right, node, 0)
          right_height -= 1
        end
        result = assemble(transaction, merge_nodes(node_for(left), node_for(right)))
        path.reverse_each do |_ref, node, index|
          node.slots[index, 1] = result.map do |ref|
            pointer = ref[0]
            raise CorruptionError, "missing B-tree pointer" unless pointer

            Slot.new(tag: :index, value: pointer)
          end
          node.counts[index, 1] = result.map { |ref| ref[1] }
          result = assemble(transaction, node)
        end
        result.size == 1 ? result.first : assemble(transaction, branch(result)).first
      end

      # Builds a subtree for an adjacent range of existing children.
      def sibling_root(transaction, ref, node, range)
        indices = node.slots.each_index.to_a[range] || []
        refs = indices.map { |index| child_ref(ref, node, index) }
        return [nil, 0, nil] if refs.empty?
        return refs.first if refs.size == 1

        assemble(transaction, branch(refs)).first
      end

      # Divides a tree at a rank and rebuilds only the split path.
      def split_root(transaction, ref, rank)
        return [[nil, 0, nil], ref] if rank.zero?
        return [ref, [nil, 0, nil]] if rank == ref[1]

        # @type var path: Array[[ref, node, Integer]]
        path = []
        # @type var seen: Hash[Integer?, bool]
        seen = {}
        node = node_for(ref)
        loop do
          raise CorruptionError, "cyclic B-tree branch" if seen[ref[0]]

          seen[ref[0]] = true
          node = node_for(ref)
          break if node.kind.zero?

          index = 0
          while index + 1 < node.slots.size && rank > node.counts[index]
            rank -= node.counts[index]
            index += 1
          end
          path << [ref, node, index]
          ref = child_ref(ref, node, index)
        end
        left = assemble(transaction, Node.new(0, node.slots.first(rank), [])).first
        right = assemble(transaction, Node.new(0, node.slots.drop(rank), [])).first
        path.reverse_each do |parent_ref, parent, index|
          left = join_roots(transaction, sibling_root(transaction, parent_ref, parent, 0...index), left)
          right = join_roots(transaction, right,
                             sibling_root(transaction, parent_ref, parent, (index + 1)...parent.slots.size))
        end
        [left, right]
      end

      # Creates a new transaction-owned cursor for a shared subtree root.
      def detached(transaction, ref)
        pointer = ref[0] || write_node(transaction, Node.new(0, [], []))
        position = transaction.append([ref[1], pointer].pack("Q>Q>"))
        self.class.new(transaction.cursor(slot: Slot.new(tag: :linked_array_list, value: position)))
      end

      # Encodes a node, reusing storage only at or above the writable boundary.
      def write_node(transaction, node, old_pointer = nil)
        bytes = [node.kind, node.slots.size].pack("CC")
        bytes << node.slots.map(&:to_bytes).join << ("\0".b * ((CAPACITY - node.slots.size) * Slot::SIZE))
        bytes << (node.counts + ([0] * (CAPACITY - node.counts.size))).pack("Q>*") unless node.kind.zero?
        if old_pointer && old_pointer >= transaction.mutable_start
          transaction.write_at(old_pointer, bytes)
          old_pointer
        else
          transaction.append(bytes)
        end
      end

      # Writes one node or splits its overflow into two balanced nodes.
      def write_split(transaction, node, old_pointer)
        return [[write_node(transaction, node, old_pointer), node.size]] if node.slots.size <= CAPACITY

        left = Node.new(node.kind, node.slots.first(SPLIT_COUNT), node.counts.first(SPLIT_COUNT))
        right = Node.new(node.kind, node.slots.drop(SPLIT_COUNT), node.counts.drop(SPLIT_COUNT))
        [[write_node(transaction, left, old_pointer), left.size], [write_node(transaction, right), right.size]]
      end

      # Updates the collection header and propagates its slot through ancestors.
      def publish(transaction, count, pointer, propagate: true)
        bytes = [count, pointer].pack("Q>Q>")
        old = cursor.slot
        position = if old.tag == @tag && old.value >= transaction.mutable_start
                     transaction.write_at(old.value, bytes)
                     old.value
                   else
                     transaction.append(bytes)
                   end
        cursor.update_collection(Slot.new(tag: @tag, value: position), propagate: propagate)
      end
    end
  end
end
