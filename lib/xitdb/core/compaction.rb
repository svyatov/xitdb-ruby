# frozen_string_literal: true

require_relative "offset_map"

module XitDB
  module Core
    class Compaction
      INLINE_TAGS = %i[none uint int float short_bytes].freeze
      BLOCK_SIZE = 16 * Slot::SIZE

      def initialize(source, cursor, transaction, offsets)
        @source = source
        @bound = cursor.bound
        @transaction = transaction
        @offsets = offsets
        @stack = []
      end

      def copy(slot)
        result = remap(slot)
        until @stack.empty?
          kind, source, target, *arguments = @stack.pop
          send(kind, source, target, *arguments)
        end
        result
      end

      private

      def read(offset, size)
        @source.read_at(offset, size, bound: @bound)
      end

      def parse(bytes)
        slot = Slot.parse(bytes)
        raise CorruptionError, "unknown compaction slot tag" unless Slot::TAGS.include?(slot.tag)

        slot
      end

      def remap(slot)
        return slot if INLINE_TAGS.include?(slot.tag)

        pointer = case slot.tag
        when :bytes then copy_bytes(slot)
        when :index, :hash_map, :hash_set then reserve(slot.value, BLOCK_SIZE, :slots, 0, 16)
        when :counted_hash_map, :counted_hash_set then reserve(slot.value, BLOCK_SIZE + 8, :slots, 8, 16)
        when :array_list then reserve(slot.value, 16, :array_header)
        when :linked_array_list then reserve(slot.value, 16, :tree_header, false)
        when :sorted_map, :sorted_set then reserve(slot.value, 16, :tree_header, true)
        when :kv_pair then reserve(slot.value, @source.header.hash_size + 18, :slots, @source.header.hash_size, 2)
        when :sorted_kv_pair then reserve(slot.value, 18, :slots, 0, 2)
        else raise CorruptionError, "unknown compaction slot tag"
        end
        Slot.new(tag: slot.tag, full: slot.full, value: pointer)
      end

      def reserve(source, size, kind, *arguments, cache: true)
        mapped = @offsets.fetch(source) if cache
        return mapped if mapped

        bytes = read(source, size)
        target = @transaction.append(bytes)
        @offsets.store(source, target) if cache
        @stack << [kind, source, target, *arguments]
        target
      end

      def copy_bytes(slot)
        mapped = @offsets.fetch(slot.value)
        return mapped if mapped

        source = Bytes.open(@source, slot, bound: @bound)
        copied = Bytes.append(@transaction, size: source.size, format_tag: source.format_tag,
          representation: :external) { |position, length| source.read(position, length) }
        target = copied.value
        @offsets.store(slot.value, target)
        target
      end

      def slots(source, target, start, count)
        count.times do |index|
          offset = start + index * Slot::SIZE
          slot = parse(read(source + offset, Slot::SIZE))
          @transaction.write_at(target + offset, remap(slot).to_bytes)
        end
      end

      def array_header(source, target)
        size, pointer = read(source, 16).unpack("Q>Q>")
        shift = [((size - 1).bit_length - 1) / 4, 0].max
        mapped = array_index(pointer, size, shift)
        @transaction.write_at(target, [size, mapped].pack("Q>Q>"))
      end

      def array_index(source, size, shift)
        return reserve(source, BLOCK_SIZE, :slots, 0, 16) if size == 16**(shift + 1)

        reserve(source, BLOCK_SIZE, :partial_array, size, shift, cache: false)
      end

      def partial_array(source, target, size, shift)
        # Partial blocks can be shared by arrays with different visible sizes.
        # Copy them separately and clear every slot outside this array's size.
        @transaction.write_at(target, "\0".b * BLOCK_SIZE)
        child_size = 16**shift
        16.times do |index|
          break unless size.positive?

          slot = parse(read(source + index * Slot::SIZE, Slot::SIZE))
          mapped = if shift.zero? || slot.empty?
            remap(slot)
          else
            raise CorruptionError, "invalid array branch" unless slot.tag == :index

            Slot.new(tag: :index, full: slot.full, value: array_index(slot.value, [size, child_size].min, shift - 1))
          end
          @transaction.write_at(target + index * Slot::SIZE, mapped.to_bytes)
          size -= [size, child_size].min
        end
      end

      def tree_header(source, target, sorted)
        size, pointer = read(source, 16).unpack("Q>Q>")
        @transaction.write_at(target, [size, tree_node(pointer, sorted)].pack("Q>Q>"))
      end

      def tree_node(source, sorted)
        mapped = @offsets.fetch(source)
        return mapped if mapped

        kind, count = read(source, 2).unpack("CC")
        raise CorruptionError, "invalid compaction B-tree node" unless kind <= 1 && count <= 16

        size = 2 + BLOCK_SIZE + (kind == 1 ? 128 + (sorted ? BLOCK_SIZE : 0) : 0)
        reserve(source, size, kind.zero? ? :slots : :tree_branch, *(kind.zero? ? [2, 16] : [sorted]))
      end

      def tree_branch(source, target, sorted)
        16.times do |index|
          offset = 2 + index * Slot::SIZE
          slot = parse(read(source + offset, Slot::SIZE))
          if slot.tag == :index
            slot = Slot.new(tag: :index, full: slot.full, value: tree_node(slot.value, sorted))
          end
          @transaction.write_at(target + offset, slot.to_bytes)
        end
        slots(source, target, 2 + BLOCK_SIZE, 16) if sorted
      end
    end
  end
end
