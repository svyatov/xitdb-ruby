# frozen_string_literal: true

module XitDB
  module Verification
    # Reads individual slots after Graph has checked physical layout and routing.
    module RubyStorage
      Field = Data.define(:slot, :offset)

      private

      def uint(offset)
        Core::Format.unsigned(@scan.read(offset, 8))
      end

      def slot_at(offset)
        Core::Slot.parse(@scan.read(offset, Core::Slot::SIZE))
      end

      def expect!(slot, tag, offset)
        invalid!(:layout, offset) unless slot.tag == tag && !slot.full?
        slot
      end

      def invalid!(check, offset)
        message = "invalid Ruby #{check.to_s.tr("_", " ")}"
        raise VerificationError.new(message, check: check, offset: offset, path: @graph.path)
      end

      # Returns the leaf, its source location and the first index after a sparse branch.
      def array_entry(array, count, index)
        block = uint(array.value + 8)
        [((count - 1).bit_length - 1) / 4, 0].max.downto(0) do |level|
          shift = level * 4
          offset = block + (((index >> shift) & 15) * 9)
          slot = slot_at(offset)
          return [slot, offset, ((index >> shift) + 1) << shift] if level.zero? || slot.empty?

          block = slot.value
        end
        raise CorruptionError, "missing array leaf"
      end

      def fields!(array, count, offset)
        expect!(array, :array_list, offset)
        invalid!(:record_arity, array.value) unless uint(array.value) == count
        fixed_fields(array, count)
      end

      # Ruby envelopes and index records fit in a single sixteen-slot block.
      def fixed_fields(array, count)
        block = uint(array.value + 8)
        Array.new(count) do |index|
          position = block + (index * Core::Slot::SIZE)
          Field.new(slot_at(position), position)
        end
      end

      def field_slot!(field, tag)
        expect!(field.slot, tag, field.offset)
      end

      def tree_entry(tree, rank)
        pointer = uint(tree.value + 8)
        loop do
          kind, count = Core::Format.pair(@scan.read(pointer, 2), "CC")
          if kind.zero?
            offset = pointer + 2 + (rank * 9)
            return [slot_at(offset), offset]
          end
          counts = pointer + (tree.tag == :linked_array_list ? Core::BTree::LEAF_SIZE : 290)
          branch = (0...count).find do |i|
            size = uint(counts + (i * 8))
            selected = rank < size
            rank -= size unless selected
            selected
          end
          invalid!(:count, counts) unless branch
          pointer = slot_at(pointer + 2 + (branch * 9)).value
        end
      end

      def sorted_pair(tree, rank)
        slot, offset = tree_entry(tree, rank)
        return [Field.new(slot, offset), Field.new(Core::Slot.new, offset)] if Graph::BYTE_TAGS.include?(slot.tag)

        key = slot.value + (slot.tag == :kv_pair ? @scan.header.hash_size : 0)
        [Field.new(slot_at(key), key), Field.new(slot_at(key + 9), key + 9)]
      end

      def lookup_pair!(lookup, digest, offset)
        block = lookup.value + 8
        digest.reverse.each_byte do |byte|
          [byte & 15, byte >> 4].each do |index|
            slot = slot_at(block + (index * 9))
            if slot.tag == :kv_pair && @scan.read(slot.value, 32) == digest
              key = slot.value + 32
              return [Field.new(slot_at(key), key), Field.new(slot_at(key + 9), key + 9)]
            end

            invalid!(:index_membership, offset) unless slot.tag == :index
            block = slot.value
          end
        end
        invalid!(:index_membership, offset)
      end

      def byte_size(slot)
        return uint(slot.value) if slot.tag == :bytes

        inline_data(slot).bytesize
      end

      def inline_data(slot)
        raw = [slot.value].pack("Q>")
        raw = Core::Format.slice(raw, 0, slot.full? ? 6 : 8)
        Core::Format.slice(raw, 0, raw.index("\0") || raw.bytesize)
      end

      def byte_data(slot, size)
        return inline_data(slot) if slot.tag == :short_bytes

        data = +"".b
        while data.bytesize < size
          data << @scan.read(slot.value + 8 + data.bytesize, [size - data.bytesize, Scan::CHUNK_SIZE].min)
        end
        data
      end

      def raw_bytes!(slot, size, offset)
        valid = Graph::BYTE_TAGS.include?(slot.tag) && !slot.full? && byte_size(slot) == size
        invalid!(:key_identity, offset) unless valid
        byte_data(slot, size)
      end
    end
  end
end
