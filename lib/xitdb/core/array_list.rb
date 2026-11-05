# frozen_string_literal: true

module XitDB
  module Core
    # A persistent vector with sixteen-way branches.
    class ArrayList
      include Enumerable

      HEADER_SIZE = 16
      BLOCK_SIZE = 16 * Slot::SIZE
      EMPTY_BLOCK = ("\0".b * BLOCK_SIZE).freeze

      attr_reader :cursor

      def initialize(cursor)
        @cursor = cursor
        unless %i[none array_list].include?(cursor.slot.tag)
          raise InvalidValueError, "slot does not contain an array list"
        end

        return unless cursor.slot.tag == :none && cursor.transaction

        mutate do |transaction|
          _count, _pointer, start = writable_header(transaction)
          cursor.update_collection(Slot.new(tag: :array_list, value: start))
        end
      end

      def size
        header.first
      end

      def get(index)
        count, pointer = header
        index = resolve_index(index, count)
        return nil unless index
        raise CorruptionError, "missing array pointer" unless pointer

        read_element(pointer, index, depth(count))
      end

      def cursor_at(index, create: false)
        count = size
        resolved = resolve_index(index, count)
        if !resolved && create
          raise IndexError, "array index outside list" unless index == count

          append(Slot.new)
          resolved = index
        end
        return nil unless resolved

        slot = get(resolved)
        raise CorruptionError, "missing array element" unless slot

        cursor.array_child(resolved, slot)
      end

      def append(slot)
        validate_slot(slot)
        mutate do |transaction|
          count, pointer, start = writable_header(transaction)
          raise RangeError, "array size exceeds unsigned 64-bit range" if count == Format::UINT64_MAX

          if depth(count + 1) > depth(count)
            pointer = transaction.append(Slot.new(tag: :index, value: pointer).to_bytes + Format.slice(EMPTY_BLOCK, Slot::SIZE..))
          end
          position = writable_element(transaction, pointer, count, depth(count + 1))
          transaction.write_at(position, slot.to_bytes)
          transaction.write_at(start, [count + 1, pointer].pack("Q>Q>"))
          cursor.update_collection(Slot.new(tag: :array_list, value: start))
        end
        self
      end

      def put(index, slot)
        replace_child(index, slot)
        self
      end

      # A child write updates its current path, including ancestors copied by freeze.
      def replace_child(index, slot, owner: nil, collection: false, propagate: true)
        validate_slot(slot)
        index = resolve_index(index, size)
        raise IndexError, "array index outside list" unless index

        mutate do |transaction|
          count, pointer, start = writable_header(transaction)
          position = writable_element(transaction, pointer, index, depth(count))
          transaction.write_at(position, slot.to_bytes)
          cursor.update_collection(Slot.new(tag: :array_list, value: start), propagate: propagate)
          cursor.invalidate_children(index: index, except: owner) unless collection
        end
        self
      end

      def truncate(count)
        Format.integer(count, 0..Format::UINT64_MAX)
        raise IndexError, "array size outside list" if count > size

        mutate do |transaction|
          previous, pointer, start = writable_header(transaction)
          shift = depth(previous)
          while shift > depth(count)
            slot = read_slot(pointer)
            if slot.empty?
              pointer = transaction.append(EMPTY_BLOCK)
              break
            end
            raise CorruptionError, "invalid array branch" unless slot.tag == :index

            pointer = slot.value
            shift -= 1
          end
          pointer = copy_block(transaction, pointer)
          transaction.write_at(start, [count, pointer].pack("Q>Q>"))
          cursor.update_collection(Slot.new(tag: :array_list, value: start))
          cursor.invalidate_children(from: count)
        end
        self
      end

      def each
        return enum_for(:each) unless block_given?

        count, pointer = header
        return self if count.zero?

        # @type var stack: Array[[Integer?, Integer, Integer]]
        stack = [[pointer, depth(count), 0]]
        until stack.empty?
          pointer, shift, base = stack.pop || raise(CorruptionError, "missing array branch")
          if pointer.nil?
            [1 << ((shift + 1) * 4), count - base].min.times { yield Slot.new }
            next
          end
          block = read(pointer, BLOCK_SIZE)
          if shift.zero?
            [16, count - base].min.times do |i|
              slot = parse_slot(Format.slice(block, i * Slot::SIZE, Slot::SIZE))
              raise CorruptionError, "index slot in array leaf" if slot.tag == :index

              yield slot
            end
          else
            stack.concat(branches(block, shift, base, count))
          end
        end
        self
      end

      private

      def branches(block, shift, base, count)
        # @type var result: Array[[Integer?, Integer, Integer]]
        result = []
        15.downto(0) do |index|
          next_base = base + (index * (1 << (shift * 4)))
          next if next_base >= count

          slot = parse_slot(Format.slice(block, index * Slot::SIZE, Slot::SIZE))
          raise CorruptionError, "invalid array branch" unless slot.empty? || slot.tag == :index

          result << [slot.empty? ? nil : slot.value, shift - 1, next_base]
        end
        result
      end

      def header
        slot = cursor.slot
        return [0, nil] if slot.tag == :none
        raise InvalidValueError, "slot does not contain an array list" unless slot.tag == :array_list

        count, pointer = Format.pair(read(slot.value, HEADER_SIZE), "Q>Q>")
        read(pointer, BLOCK_SIZE)
        [count, pointer]
      end

      def depth(count)
        [((count - 1).bit_length - 1) / 4, 0].max
      end

      def resolve_index(index, count)
        raise TypeError, "array index must be an Integer" unless index.is_a?(Integer)

        index += count if index.negative?
        index if index >= 0 && index < count
      end

      def read(offset, length)
        cursor.database.read_at(offset, length, bound: cursor.bound)
      end

      def parse_slot(bytes)
        slot = Slot.parse(bytes)
        raise CorruptionError, "unknown array slot tag" unless Slot::TAGS.include?(slot.tag)

        slot
      end

      def read_slot(offset)
        parse_slot(read(offset, Slot::SIZE))
      end

      def read_element(pointer, index, shift)
        loop do
          read(pointer, BLOCK_SIZE)
          slot = read_slot(pointer + (((index >> (shift * 4)) & 15) * Slot::SIZE))
          if shift.zero?
            raise CorruptionError, "index slot in array leaf" if slot.tag == :index

            return slot
          end
          return Slot.new if slot.empty?
          raise CorruptionError, "invalid array branch" unless slot.tag == :index

          pointer = slot.value
          shift -= 1
        end
      end

      def validate_slot(slot)
        raise TypeError, "expected Slot" unless slot.is_a?(Slot)
        raise CorruptionError, "unknown slot tag" unless Slot::TAGS.include?(slot.tag)
        raise InvalidValueError, "index slot is internal to array branches" if slot.tag == :index
      end

      def mutate
        cursor.slot
        transaction = cursor.transaction
        raise ReadOnlyError, "array list is read-only" unless transaction

        checkpoint = transaction.checkpoint
        begin
          yield transaction
        rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
          transaction.restore(checkpoint)
          raise
        else
          transaction.release_checkpoint(checkpoint)
        end
      end

      def writable_header(transaction)
        count, pointer = header
        if pointer.nil?
          start = transaction.length
          pointer = start + HEADER_SIZE
          transaction.append([0, pointer].pack("Q>Q>") + EMPTY_BLOCK)
        else
          pointer = copy_block(transaction, pointer)
          start = transaction.append([count, pointer].pack("Q>Q>"))
        end
        [count, pointer, start]
      end

      def copy_block(transaction, pointer)
        block = transaction.read_at(pointer, BLOCK_SIZE)
        pointer < transaction.mutable_start ? transaction.append(block) : pointer
      end

      def writable_element(transaction, pointer, index, shift)
        loop do
          position = pointer + (((index >> (shift * 4)) & 15) * Slot::SIZE)
          return position if shift.zero?

          slot = read_slot(position)
          next_pointer = if slot.empty?
                           transaction.append(EMPTY_BLOCK)
                         elsif slot.tag == :index
                           copy_block(transaction, slot.value)
                         else
                           raise CorruptionError, "invalid array branch"
                         end
          transaction.write_at(position, Slot.new(tag: :index, value: next_pointer).to_bytes)
          pointer = next_pointer
          shift -= 1
        end
      end
    end
  end
end
