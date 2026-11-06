# frozen_string_literal: true

require_relative "offset_map"

module XitDB
  module Core
    # A copier that retains reachable records and remaps their byte offsets.
    #
    # An explicit work stack avoids recursive traversal. The offset table preserves sharing between copied records.
    # @api private
    class Compaction
      # Slot tags whose value field contains data rather than a record offset.
      INLINE_TAGS = %i[none uint int float short_bytes].freeze
      # Bytes in a block of sixteen copied slot descriptors.
      BLOCK_SIZE = 16 * Slot::SIZE

      # Creates a copier bound to one source view and destination transaction.
      # @param source [Database] database containing the source records
      # @param cursor [Cursor] view locating this collection or value
      # @param transaction [Transaction] active destination transaction
      # @param offsets [OffsetMap] lookup table retaining source-to-destination offset mappings
      # @return [Compaction]
      def initialize(source, cursor, transaction, offsets)
        @source = source
        @bound = cursor.bound
        @transaction = transaction
        @offsets = offsets
        @stack = []
      end

      # Copies a reachable slot graph and rewrites pointers to destination offsets.
      # @param slot [Slot] stored value or record descriptor
      # @return [Slot]
      def copy(slot)
        result = remap(slot)
        @stack.pop&.call until @stack.empty?
        result
      end

      private

      # Reads source bytes within the captured view boundary.
      def read(offset, size)
        @source.read_at(offset, size, bound: @bound)
      end

      # Decodes a slot and rejects tags the copier cannot interpret.
      def parse(bytes)
        slot = Slot.parse(bytes)
        raise CorruptionError, "unknown compaction slot tag" unless Slot::TAGS.include?(slot.tag)

        slot
      end

      # Keeps inline values unchanged and rewrites external pointers.
      def remap(slot)
        return slot if INLINE_TAGS.include?(slot.tag)

        Slot.new(tag: slot.tag, full: slot.full?, value: remap_pointer(slot))
      end

      # Selects the record layout that determines which child pointers require copying.
      def remap_pointer(slot)
        case slot.tag
        when :bytes then copy_bytes(slot)
        when :index, :hash_map, :hash_set then reserve_slots(slot.value, BLOCK_SIZE, 0, 16)
        when :counted_hash_map, :counted_hash_set then reserve_slots(slot.value, BLOCK_SIZE + 8, 8, 16)
        when :array_list then reserve(slot.value, 16) { |source, target| array_header(source, target) }
        when :linked_array_list then reserve(slot.value, 16) do |source, target|
          tree_header(source, target, false)
        end
        when :sorted_map, :sorted_set then reserve(slot.value, 16) do |source, target|
          tree_header(source, target, true)
        end
        when :kv_pair then reserve_slots(slot.value, @source.header.hash_size + 18,
                                         @source.header.hash_size, 2)
        when :sorted_kv_pair then reserve_slots(slot.value, 18, 0, 2)
        else raise CorruptionError, "unknown compaction slot tag"
        end
      end

      # Reserves a copied record and schedules child slots for rewriting.
      def reserve_slots(source, size, start, count)
        reserve(source, size) { |origin, target| slots(origin, target, start, count) }
      end

      # Reuses a known offset or reserves storage before scheduling pointer rewrites.
      def reserve(source, size, cache: true)
        mapped = @offsets.fetch(source) if cache
        return mapped if mapped

        bytes = read(source, size)
        target = @transaction.append(bytes)
        @offsets.store(source, target) if cache
        @stack << -> { yield(source, target) }
        target
      end

      # Copies a byte payload in chunks and records its destination offset.
      def copy_bytes(slot)
        mapped = @offsets.fetch(slot.value)
        return mapped if mapped

        source = Bytes.open(@source, slot, bound: @bound)
        copied = Bytes.append(@transaction, size: source.size, format_tag: source.format_tag,
                                            representation: :external) do |position, length|
          source.read(position,
                      length)
        end
        target = copied.value
        @offsets.store(slot.value, target)
        target
      end

      # Rewrites child slots in a previously reserved destination record.
      def slots(source, target, start, count)
        count.times do |index|
          offset = start + (index * Slot::SIZE)
          slot = parse(read(source + offset, Slot::SIZE))
          @transaction.write_at(target + offset, remap(slot).to_bytes)
        end
      end

      # Copies an array root using only elements inside its visible count.
      def array_header(source, target)
        size, pointer = Format.pair(read(source, 16), "Q>Q>")
        shift = [((size - 1).bit_length - 1) / 4, 0].max
        mapped = array_index(pointer, size, shift)
        @transaction.write_at(target, [size, mapped].pack("Q>Q>"))
      end

      # Shares full copied blocks and separately copies partially visible blocks.
      def array_index(source, size, shift)
        return reserve_slots(source, BLOCK_SIZE, 0, 16) if size == 1 << ((shift + 1) * 4)

        reserve(source, BLOCK_SIZE, cache: false) { |origin, target| partial_array(origin, target, size, shift) }
      end

      # Clears hidden positions and remaps only visible slots in a partial array block.
      def partial_array(source, target, size, shift)
        # Partial blocks can be shared by arrays with different visible sizes.
        # Copy them separately and clear every slot outside this array's size.
        @transaction.write_at(target, "\0".b * BLOCK_SIZE)
        child_size = 1 << (shift * 4)
        16.times do |index|
          break unless size.positive?

          slot = parse(read(source + (index * Slot::SIZE), Slot::SIZE))
          mapped = if shift.zero? || slot.empty?
                     remap(slot)
                   else
                     raise CorruptionError, "invalid array branch" unless slot.tag == :index

                     Slot.new(tag: :index, full: slot.full?,
                              value: array_index(slot.value, [size, child_size].min, shift - 1))
                   end
          @transaction.write_at(target + (index * Slot::SIZE), mapped.to_bytes)
          size -= [size, child_size].min
        end
      end

      # Rewrites a counted tree header to its copied root node.
      def tree_header(source, target, sorted)
        size, pointer = Format.pair(read(source, 16), "Q>Q>")
        @transaction.write_at(target, [size, tree_node(pointer, sorted)].pack("Q>Q>"))
      end

      # Reserves a tree node according to its kind and sorted layout.
      def tree_node(source, sorted)
        mapped = @offsets.fetch(source)
        return mapped if mapped

        kind, count = Format.pair(read(source, 2), "CC")
        raise CorruptionError, "invalid compaction B-tree node" unless kind <= 1 && count <= 16

        size = 2 + BLOCK_SIZE + (if kind == 1
                                   128 + (sorted ? BLOCK_SIZE : 0)
                                 else
                                   0
                                 end)
        if kind.zero?
          reserve_slots(source, size, 2, 16)
        else
          reserve(source, size) { |origin, target| tree_branch(origin, target, sorted) }
        end
      end

      # Rewrites child node pointers and sorted separator slots in a branch.
      def tree_branch(source, target, sorted)
        16.times do |index|
          offset = 2 + (index * Slot::SIZE)
          slot = parse(read(source + offset, Slot::SIZE))
          slot = Slot.new(tag: :index, full: slot.full?, value: tree_node(slot.value, sorted)) if slot.tag == :index
          @transaction.write_at(target + offset, slot.to_bytes)
        end
        slots(source, target, 2 + BLOCK_SIZE, 16) if sorted
      end
    end
  end
end
