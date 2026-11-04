# frozen_string_literal: true

module XitDB
  module Core
    class BTree
      HEADER_SIZE = 16
      CAPACITY = 16
      SPLIT_COUNT = 8
      LEAF_SIZE = 146
      BRANCH_SIZE = 274
      Node = Struct.new(:kind, :slots, :counts) do
        def size
          kind.zero? ? slots.size : counts.sum
        end
      end
      private_constant :Node

      attr_reader :cursor

      def initialize(cursor, tag: :linked_array_list)
        @cursor = cursor
        @tag = tag
        unless [:none, @tag].include?(cursor.slot.tag)
          raise InvalidValueError, "slot does not contain a linked array list"
        end
        if cursor.slot.tag == :none && cursor.transaction
          mutate do |tx|
            pointer = write_node(tx, Node.new(0, [], []))
            publish(tx, 0, pointer)
          end
        end
      end

      def size
        header.first
      end

      def at(index)
        count, pointer = header
        rank = resolve_index(index, count)
        return nil unless rank

        _path, node, rank = descend(pointer, rank, count)
        node.slots.fetch(rank)
      end

      def insert(index, slot)
        validate_slot(slot)
        count, pointer = header
        integer_index(index)
        raise IndexError, "array index outside list" unless index >= 0 && index <= count
        raise RangeError, "array size exceeds unsigned 64-bit range" if count == Format::UINT64_MAX

        mutate do |tx|
          path, node, rank = descend(pointer, index, count, insertion: true)
          node.slots.insert(rank, slot)
          result = write_split(tx, node, pointer_for(path, pointer))
          path.reverse_each do |parent_pointer, parent, child_index|
            parent.slots[child_index, 1] = result.map { |ptr, _| Slot.new(tag: :index, value: ptr) }
            parent.counts[child_index, 1] = result.map(&:last)
            result = write_split(tx, parent, parent_pointer)
          end
          root_pointer = if result.size == 1
            result.first.first
          else
            write_node(tx, Node.new(1, result.map { |ptr, _| Slot.new(tag: :index, value: ptr) }, result.map(&:last)))
          end
          publish(tx, count + 1, root_pointer)
          cursor.invalidate_children(from: index)
        end
        self
      end

      def replace(index, slot, owner: nil, collection: false, propagate: true)
        validate_slot(slot)
        count, pointer = header
        rank = resolve_index(index, count)
        raise IndexError, "array index outside list" unless rank

        mutate do |tx|
          path, node, rank = descend(pointer, rank, count)
          node.slots[rank] = slot
          child_pointer = write_node(tx, node, pointer_for(path, pointer))
          path.reverse_each do |parent_pointer, parent, child_index|
            parent.slots[child_index] = Slot.new(tag: :index, value: child_pointer)
            child_pointer = write_node(tx, parent, parent_pointer)
          end
          publish(tx, count, child_pointer, propagate: propagate)
          cursor.invalidate_children(index: resolve_index(index, count), except: owner) unless collection
        end
        self
      end

      def delete_at(index)
        count, pointer = header
        rank = resolve_index(index, count)
        return nil unless rank

        mutate do |tx|
          path, node, offset = descend(pointer, rank, count)
          removed = node.slots.delete_at(offset)
          old_pointer = pointer_for(path, pointer)
          path.reverse_each do |parent_pointer, parent, child_index|
            if node.slots.empty?
              parent.slots.delete_at(child_index)
              parent.counts.delete_at(child_index)
            else
              if node.slots.size < SPLIT_COUNT && parent.slots.size > 1
                first = child_index + 1 < parent.slots.size ? child_index : child_index - 1
                neighbor_index = first == child_index ? first + 1 : first
                neighbor = read_node(parent.slots[neighbor_index].value, parent.counts[neighbor_index])
                raise CorruptionError, "unequal B-tree child heights" unless neighbor.kind == node.kind

                if node.slots.size + neighbor.slots.size <= CAPACITY
                  node = first == child_index ? merge_nodes(node, neighbor) : merge_nodes(neighbor, node)
                  parent.slots.delete_at(first + 1)
                  parent.counts.delete_at(first + 1)
                  child_index = first
                end
              end
              parent.slots[child_index] = Slot.new(tag: :index, value: write_node(tx, node, old_pointer))
              parent.counts[child_index] = node.size
            end
            node = parent
            old_pointer = parent_pointer
          end
          if node.kind == 1 && node.slots.size == 1
            root_pointer = node.slots.first.value
            seen = {}
            loop do
              raise CorruptionError, "cyclic B-tree branch" if seen[root_pointer]

              seen[root_pointer] = true
              child = read_node(root_pointer, count - 1)
              break unless child.kind == 1 && child.slots.size == 1

              root_pointer = child.slots.first.value
            end
          else
            node = Node.new(0, [], []) if node.slots.empty?
            root_pointer = write_node(tx, node, old_pointer)
          end
          publish(tx, count - 1, root_pointer)
          cursor.invalidate_children(from: rank)
          removed
        end
      end

      def split(index)
        count, pointer = header
        integer_index(index)
        index += count if index.negative?
        raise IndexError, "array split outside list" unless index >= 0 && index <= count

        mutate do |tx|
          split_root(tx, [pointer, count, cursor.bound], index).map { |ref| detached(tx, ref) }
        end
      end

      def slice(start, length)
        count, pointer = header
        integer_index(start)
        integer_index(length)
        start += count if start.negative?
        unless start >= 0 && start <= count && length >= 0 && length <= count - start
          raise IndexError, "array slice outside list"
        end

        mutate do |tx|
          _left, tail = split_root(tx, [pointer, count, cursor.bound], start)
          selected, _right = split_root(tx, tail, length)
          detached(tx, selected)
        end
      end

      def concat(other)
        raise TypeError, "expected BTree" unless other.is_a?(BTree)
        unless cursor.database.equal?(other.cursor.database)
          raise ForeignValueError, "cannot share linked arrays across databases"
        end

        count, pointer = header
        other_count, other_pointer = other.send(:header)
        raise RangeError, "array size exceeds unsigned 64-bit range" if count + other_count > Format::UINT64_MAX

        mutate do |tx|
          ref = join_roots(tx, [pointer, count, cursor.bound], [other_pointer, other_count, other.cursor.bound])
          detached(tx, ref)
        end
      end

      def each_from_index(index)
        return enum_for(__method__, index) unless block_given?

        count, pointer = header
        integer_index(index)
        index += count if index.negative?
        return self unless index >= 0 && index < count

        path, node, rank = descend(pointer, index, count)
        loop do
          node.slots.drop(rank).each { |slot| yield slot }
          frame = nil
          until path.empty?
            candidate = path.pop
            if candidate[2] + 1 < candidate[1].slots.size
              frame = candidate
              break
            end
          end
          break unless frame

          parent_pointer, parent, child_index = frame
          child_index += 1
          path << [parent_pointer, parent, child_index]
          subpath, node, rank = descend(parent.slots[child_index].value, 0, parent.counts[child_index], ancestors: path.map(&:first))
          path.concat(subpath)
        end
        self
      end

      private

      def integer_index(index)
        raise TypeError, "array index must be an Integer" unless index.is_a?(Integer)
      end

      def resolve_index(index, count)
        integer_index(index)
        index += count if index.negative?
        index if index >= 0 && index < count
      end

      def read(offset, length, bound: cursor.bound)
        cursor.database.read_at(offset, length, bound: bound)
      end

      def header
        slot = cursor.slot
        return [0, nil] if slot.tag == :none
        raise InvalidValueError, "slot does not contain the expected B-tree type" unless slot.tag == @tag

        read(slot.value, HEADER_SIZE).unpack("Q>Q>")
      end

      def read_node(pointer, expected, bound: cursor.bound)
        kind, num = read(pointer, 2, bound: bound).unpack("CC")
        unless [0, 1].include?(kind) && num <= CAPACITY && (kind.zero? || num.positive?)
          raise CorruptionError, "invalid B-tree node header"
        end
        bytes = read(pointer, kind.zero? ? LEAF_SIZE : BRANCH_SIZE, bound: bound)
        slots = CAPACITY.times.map do |i|
          slot = Slot.parse(bytes.byteslice(2 + i * Slot::SIZE, Slot::SIZE))
          raise CorruptionError, "unknown B-tree slot tag" unless Slot::TAGS.include?(slot.tag)

          slot
        end.first(num)
        counts = kind.zero? ? [] : bytes.byteslice(LEAF_SIZE, 128).unpack("Q>*").first(num)
        if kind == 1 && (slots.any? { |slot| slot.tag != :index } || counts.any?(&:zero?))
          raise CorruptionError, "invalid B-tree branch"
        end
        if kind.zero? && slots.any? { |slot| slot.tag == :index }
          raise CorruptionError, "index slot in B-tree leaf"
        end
        node = Node.new(kind, slots, counts)
        raise CorruptionError, "invalid B-tree subtree count" unless node.size == expected

        node
      end

      def descend(pointer, rank, expected, insertion: false, ancestors: [])
        return [[], Node.new(0, [], []), 0] unless pointer

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

      def pointer_for(path, root_pointer)
        path.empty? ? root_pointer : path.last[1].slots[path.last[2]].value
      end

      def validate_slot(slot)
        raise TypeError, "expected Slot" unless slot.is_a?(Slot)
        raise CorruptionError, "unknown slot tag" unless Slot::TAGS.include?(slot.tag)
        raise InvalidValueError, "index slot is internal to B-tree branches" if slot.tag == :index
      end

      def mutate
        cursor.slot
        tx = cursor.transaction
        raise ReadOnlyError, "linked array list is read-only" unless tx

        checkpoint = tx.checkpoint
        begin
          result = yield tx
        rescue Exception
          tx.restore(checkpoint)
          raise
        else
          tx.release_checkpoint(checkpoint)
          result
        end
      end

      # References retain each source cursor's read boundary while nodes are shared.
      def node_for(ref)
        read_node(ref[0], ref[1], bound: ref[2] || cursor.bound)
      end

      def child_ref(ref, node, index)
        [node.slots[index].value, node.counts[index], ref[2]]
      end

      def merge_nodes(left, right)
        raise CorruptionError, "unequal B-tree node kinds" unless left.kind == right.kind

        Node.new(left.kind, left.slots + right.slots, left.counts + right.counts)
      end

      def assemble(tx, node)
        if node.slots.size <= CAPACITY
          [[write_node(tx, node), node.size, nil]]
        else
          middle = node.slots.size / 2
          [Node.new(node.kind, node.slots.first(middle), node.counts.first(middle)),
           Node.new(node.kind, node.slots.drop(middle), node.counts.drop(middle))].map do |half|
            [write_node(tx, half), half.size, nil]
          end
        end
      end

      def branch(refs)
        Node.new(1, refs.map { |ref| Slot.new(tag: :index, value: ref[0]) }, refs.map { |ref| ref[1] })
      end

      def height(ref)
        levels = 0
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

      def join_roots(tx, left, right)
        return right if left[1].zero?
        return left if right[1].zero?

        left_height = height(left)
        right_height = height(right)
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
        result = assemble(tx, merge_nodes(node_for(left), node_for(right)))
        path.reverse_each do |_ref, node, index|
          node.slots[index, 1] = result.map { |ref| Slot.new(tag: :index, value: ref[0]) }
          node.counts[index, 1] = result.map { |ref| ref[1] }
          result = assemble(tx, node)
        end
        result.size == 1 ? result.first : assemble(tx, branch(result)).first
      end

      def sibling_root(tx, ref, node, range)
        refs = node.slots.each_index.to_a[range].map { |index| child_ref(ref, node, index) }
        return [nil, 0, nil] if refs.empty?
        return refs.first if refs.size == 1

        assemble(tx, branch(refs)).first
      end

      def split_root(tx, ref, rank)
        return [[nil, 0, nil], ref] if rank.zero?
        return [ref, [nil, 0, nil]] if rank == ref[1]

        path = []
        seen = {}
        node = nil
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
        left = assemble(tx, Node.new(0, node.slots.first(rank), [])).first
        right = assemble(tx, Node.new(0, node.slots.drop(rank), [])).first
        path.reverse_each do |parent_ref, parent, index|
          left = join_roots(tx, sibling_root(tx, parent_ref, parent, 0...index), left)
          right = join_roots(tx, right, sibling_root(tx, parent_ref, parent, (index + 1)...parent.slots.size))
        end
        [left, right]
      end

      def detached(tx, ref)
        pointer = ref[0] || write_node(tx, Node.new(0, [], []))
        position = tx.append([ref[1], pointer].pack("Q>Q>"))
        self.class.new(tx.cursor(slot: Slot.new(tag: :linked_array_list, value: position)))
      end

      def write_node(tx, node, old_pointer = nil)
        bytes = [node.kind, node.slots.size].pack("CC")
        bytes << node.slots.map(&:to_bytes).join << "\0".b * ((CAPACITY - node.slots.size) * Slot::SIZE)
        bytes << (node.counts + [0] * (CAPACITY - node.counts.size)).pack("Q>*") unless node.kind.zero?
        if old_pointer && old_pointer >= tx.mutable_start
          tx.write_at(old_pointer, bytes)
          old_pointer
        else
          tx.append(bytes)
        end
      end

      def write_split(tx, node, old_pointer)
        return [[write_node(tx, node, old_pointer), node.size]] if node.slots.size <= CAPACITY

        left = Node.new(node.kind, node.slots.first(SPLIT_COUNT), node.counts.first(SPLIT_COUNT))
        right = Node.new(node.kind, node.slots.drop(SPLIT_COUNT), node.counts.drop(SPLIT_COUNT))
        [[write_node(tx, left, old_pointer), left.size], [write_node(tx, right), right.size]]
      end

      def publish(tx, count, pointer, propagate: true)
        bytes = [count, pointer].pack("Q>Q>")
        old = cursor.slot
        position = if old.tag == @tag && old.value >= tx.mutable_start
          tx.write_at(old.value, bytes)
          old.value
        else
          tx.append(bytes)
        end
        cursor.update_collection(Slot.new(tag: @tag, value: position), propagate: propagate)
      end
    end
  end
end
