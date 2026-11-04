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

      def initialize(cursor)
        @cursor = cursor
        unless %i[none linked_array_list].include?(cursor.slot.tag)
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

      def read(offset, length)
        cursor.database.read_at(offset, length, bound: cursor.bound)
      end

      def header
        slot = cursor.slot
        return [0, nil] if slot.tag == :none
        raise InvalidValueError, "slot does not contain a linked array list" unless slot.tag == :linked_array_list

        read(slot.value, HEADER_SIZE).unpack("Q>Q>")
      end

      def read_node(pointer, expected)
        kind, num = read(pointer, 2).unpack("CC")
        unless [0, 1].include?(kind) && num <= CAPACITY && (kind.zero? || num.positive?)
          raise CorruptionError, "invalid B-tree node header"
        end
        bytes = read(pointer, kind.zero? ? LEAF_SIZE : BRANCH_SIZE)
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
          yield tx
        rescue Exception
          tx.restore(checkpoint)
          raise
        else
          tx.release_checkpoint(checkpoint)
        end
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
        position = if old.tag == :linked_array_list && old.value >= tx.mutable_start
          tx.write_at(old.value, bytes)
          old.value
        else
          tx.append(bytes)
        end
        cursor.update_collection(Slot.new(tag: :linked_array_list, value: position), propagate: propagate)
      end
    end
  end
end
