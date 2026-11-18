# frozen_string_literal: true

module XitDB
  module Verification
    # Counts actual leaves and verifies the digest path from the root to each leaf.
    module HashIndex
      # @type instance: Graph

      private

      def hash_root(slot)
        counted = %i[counted_hash_map counted_hash_set].include?(slot.tag)
        set = %i[hash_set counted_hash_set].include?(slot.tag)
        start = slot.value
        count = if counted
                  reference(start + 8, :hash_block, [set, 0, 0], start) { hash_block(start + 8, set, 0, 0) }
                else
                  hash_block(start, set, 0, 0)
                end
        invalid!(:count, start) if counted && count != uint(start)
        count
      end

      def hash_block(pointer, set, prefix, depth)
        read(pointer, Core::HashMap::BLOCK_SIZE)
        invalid!(:hash_depth, pointer) if depth >= @scan.header.hash_size * 2
        16.times.sum do |index|
          offset = pointer + (index * 9)
          slot = slot_at(offset)
          next 0 if slot == Core::Slot.new

          hash_child(slot, offset, set, prefix | (index << (4 * depth)), depth + 1)
        end
      end

      def hash_child(slot, offset, set, prefix, depth)
        invalid!(:slot_flag, offset) if slot.full?
        case slot.tag
        when :index
          reference(slot.value, :hash_block, [set, prefix, depth], offset) do
            hash_block(slot.value, set, prefix, depth)
          end
        when :kv_pair
          reference(slot.value, :kv_pair, [:hash, set, prefix, depth], offset) do
            hash_entry(slot.value, set, prefix, depth)
          end
        else invalid!(:slot, offset)
        end
      end

      def hash_entry(pointer, set, prefix, depth)
        width = @scan.header.hash_size
        digest = read(pointer, width)
        mask = (1 << (4 * depth)) - 1
        invalid!(:hash_route, pointer) unless digest.unpack1("H*").to_s.to_i(16) & mask == prefix
        offset = pointer + width
        key = slot_at(offset)
        if @portable
          source = key_source(key, offset)
          at(key_selector(source)) do
            check_digest!(source, digest, pointer)
            hash_value(set, offset + 9)
          end
        else
          value(key, offset)
          hash_value(set, offset + 9)
        end
        1
      end

      def hash_value(set, offset)
        entry = slot_at(offset)
        invalid!(:set_value, offset) if set && entry != Core::Slot.new
        value(entry, offset)
      end

      def check_digest!(source, expected, offset)
        digest = case @scan.header.hash_size
                 when 20 then Digest::SHA1.new
                 when 32 then Digest::SHA256.new
                 when 48 then Digest::SHA384.new
                 when 64 then Digest::SHA512.new
                 else raise UnsupportedVerificationFormatError, "unknown portable digest width"
                 end
        each_chunk(source) { |chunk| digest.update(chunk) }
        invalid!(:key_digest, offset) unless digest.digest == expected
      end
    end
  end
end
