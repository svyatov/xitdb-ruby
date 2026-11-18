# frozen_string_literal: true

module XitDB
  module Verification
    # Derives subtree counts, heights and sorted key ranges from the leaves.
    module Tree
      # @type instance: Graph

      private

      def tree_root(slot)
        count, pointer = Core::Format.pair(read(slot.value, 16), "Q>Q>")
        summary = tree_node(pointer, slot.tag, slot.value + 8)
        invalid!(:count, slot.value) unless count == summary[0]
        nil
      end

      def tree_node(pointer, tag, offset)
        reference(pointer, :tree_node, tag, offset) do
          kind, count = Core::Format.pair(read(pointer, 2), "CC")
          invalid!(:node, pointer) unless count <= 16 && [0, 1].include?(kind)
          if kind.zero?
            tree_leaf(pointer, tag, count)
          else
            invalid!(:node, pointer) if count.zero?
            tree_branch(pointer, tag, count)
          end
        end
      end

      def tree_leaf(pointer, tag, count)
        read(pointer, Core::BTree::LEAF_SIZE)
        # @type var first: byte_source?
        # @type var last: byte_source?
        first = last = nil
        count.times do |index|
          offset = pointer + 2 + (index * 9)
          slot = slot_at(offset)
          if tag == :linked_array_list
            value(slot, offset)
          else
            key = sorted_entry(slot, tag, offset)
            invalid!(:key_order, offset) if last && compare(last, key) >= 0
            first ||= key
            last = key
          end
        end
        [count, 0, first, last]
      end

      def sorted_entry(slot, tag, offset)
        return key_source(slot, offset) if Graph::BYTE_TAGS.include?(slot.tag)

        invalid!(:slot, offset) unless %i[kv_pair sorted_kv_pair].include?(slot.tag) && !slot.full?
        reference(slot.value, slot.tag, [:sorted, tag], offset) do
          pointer = slot.value
          width = slot.tag == :kv_pair ? @scan.header.hash_size : 0
          digest = read(pointer, width)
          key = key_source(slot_at(pointer + width), pointer + width)
          check_digest!(key, digest, pointer) if @portable && width.positive?
          pos = pointer + width + 9
          stored = slot_at(pos)
          invalid!(:set_value, pos) if tag == :sorted_set && stored != Core::Slot.new
          value(stored, pos)
          key
        end
      end

      def tree_branch(pointer, tag, count)
        sorted = tag != :linked_array_list
        counts = sorted ? 290 : Core::BTree::LEAF_SIZE
        read(pointer, counts + 128)
        total = 0
        # @type var first: byte_source?
        # @type var last: byte_source?
        # @type var height: Integer?
        height = first = last = nil
        count.times do |index|
          offset = pointer + 2 + (index * 9)
          slot = slot_at(offset)
          expect_tag!(slot, :index, offset)
          size, child_height, low, high = tree_node(slot.value, tag, offset)
          position = pointer + counts + (index * 8)
          invalid!(:count, position) unless size.positive? && size == uint(position)
          invalid!(:height, offset) if height && child_height != height
          separator!(pointer, index, last, low) if sorted
          height = child_height
          first ||= low
          last = high
          total += size
        end
        [total, (height || invalid!(:height, pointer)) + 1, first, last]
      end

      # Deletion can leave a separator below the current right minimum.
      def separator!(pointer, index, previous, low)
        offset = pointer + Core::BTree::LEAF_SIZE + (index * 9)
        slot = slot_at(offset)
        return if index.zero? && slot == Core::Slot.new

        pivot = key_source(slot, offset)
        # Child zero has no routing separator. A split can retain an old key there.
        return if index.zero?
        return if previous && low && compare(previous, pivot).negative? && compare(pivot, low) <= 0

        invalid!(:separator, offset)
      end

      def compare(left, right)
        left_pos, left_size = left
        right_pos, right_size = right
        remaining = [left_size, right_size].min
        position = 0
        while position < remaining
          length = [Scan::CHUNK_SIZE, remaining - position].min
          order = @budget.with(:comparison_bytes, length * 2) do
            part(left_pos, position, length) <=> part(right_pos, position, length)
          end
          return order unless order.zero?

          position += length
        end
        left_size <=> right_size
      end
    end
  end
end
