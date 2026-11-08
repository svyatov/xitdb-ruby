# frozen_string_literal: true

module XitDB
  # Advanced binary storage API for slots, cursors, collections, and transactions.
  #
  # A slot describes a stored value. A cursor locates a value inside a database.
  # This layer handles encoded bytes and slots; XitDB::Database accepts application values.
  module Core
    # An indexed slot list stored in a tree with sixteen positions per block.
    #
    # Each branch uses four index bits. Missing branches read as empty slots inside the visible list length.
    #
    # Writes copy protected blocks so earlier views keep their values.
    class ArrayList
      include Enumerable

      # Bytes storing the visible element count and root block offset.
      HEADER_SIZE = 16
      # Bytes in one block of sixteen slot descriptors.
      BLOCK_SIZE = 16 * Slot::SIZE
      # A zero-filled block representing sixteen unused positions.
      EMPTY_BLOCK = ("\0".b * BLOCK_SIZE).freeze

      # @!attribute [r] cursor
      #   View locating this collection.
      #   @return [Cursor]
      attr_reader :cursor

      # Opens an indexed list, initializing an empty writable cursor when needed.
      # @param cursor [Cursor] view locating this collection or value
      # @param fields [Array<Slot>] up to sixteen initial slots for a new writable list
      # @return [ArrayList]
      # @raise [InvalidValueError] if the cursor holds an incompatible collection tag
      def initialize(cursor, fields: [])
        @cursor = cursor
        unless %i[none array_list].include?(cursor.slot.tag)
          raise InvalidValueError, "slot does not contain an array list"
        end

        validate_initial_fields!(fields) unless fields.empty?
        return unless cursor.slot.tag == :none && cursor.transaction

        mutate do |transaction|
          start = transaction.length
          block = fields.empty? ? EMPTY_BLOCK : fields.map(&:to_bytes).join.b.ljust(BLOCK_SIZE, "\0")
          transaction.append([fields.size, start + HEADER_SIZE].pack("Q>Q>") + block)
          cursor.update_collection(Slot.new(tag: :array_list, value: start))
        end
      end

      # Returns the number of visible elements.
      # @return [Integer]
      def size
        header.first
      end

      # Reads an element, with negative indexes counted from the end.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [Slot, nil]
      def get(index)
        count, pointer = header
        index = resolve_index(index, count)
        return nil unless index
        raise CorruptionError, "missing array pointer" unless pointer

        read_element(pointer, index, depth(count))
      end

      # Returns an element view, optionally appending an empty slot at the list end.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @param create [Boolean] whether to create an empty element when the requested position is absent
      # @return [Cursor, nil]
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

      # Adds a slot at the end and grows branch depth when needed.
      # @param slot [Slot] stored value or record descriptor
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      def append(slot)
        validate_slot!(slot)
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

      # Replaces an element at an existing index.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @param slot [Slot] stored value or record descriptor
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      def put(index, slot)
        replace_child(index, slot)
        self
      end

      # Replaces a child slot while preserving the owning cursor when supplied.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @param slot [Slot] stored value or record descriptor
      # @param owner [Cursor, nil] child view to preserve during replacement
      # @param collection [Boolean] whether this is an internal copied collection update
      # @param propagate [Boolean] whether to update parent collection paths immediately
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      # @api private
      def replace_child(index, slot, owner: nil, collection: false, propagate: true)
        validate_slot!(slot)
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

      # Keeps the first count elements and invalidates removed element views.
      # @param count [Integer] number of elements to retain
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      def truncate(count)
        Format.integer!(count, 0..Format::UINT64_MAX)
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

      # Visits visible slots in index order, including empty positions.
      # @return [self, Enumerator<Slot>]
      # @yield [slot] receives each visible element
      # @yieldparam slot [Slot] stored element
      # @yieldreturn [Object] ignored
      # @note Without a block, returns an Enumerator.
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

      # Checks the bounded initial record before allocating any storage.
      def validate_initial_fields!(fields)
        unless cursor.slot.empty? && cursor.transaction
          raise ArgumentError, "initial fields require an empty writable cursor"
        end
        raise ArgumentError, "initial fields exceed one array block" if fields.size > 16

        fields.each { |field| validate_slot!(field) }
      end

      # Builds reverse traversal frames for the visible branches of one block.
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

      # Reads the element count and root block pointer.
      def header
        slot = cursor.slot
        return [0, nil] if slot.tag == :none
        raise InvalidValueError, "slot does not contain an array list" unless slot.tag == :array_list

        count, pointer = Format.pair(read(slot.value, HEADER_SIZE), "Q>Q>")
        read(pointer, BLOCK_SIZE)
        [count, pointer]
      end

      # Calculates branch depth for an element count.
      def depth(count)
        [((count - 1).bit_length - 1) / 4, 0].max
      end

      # Normalizes a negative index and returns nil outside the visible list.
      def resolve_index(index, count)
        raise TypeError, "array index must be an Integer" unless index.is_a?(Integer)

        index += count if index.negative?
        index if index >= 0 && index < count
      end

      # Reads bytes inside the collection cursor's boundary.
      def read(offset, length)
        cursor.database.read_at(offset, length, bound: cursor.bound)
      end

      # Decodes a slot and rejects unrecognized array tags.
      def parse_slot(bytes)
        slot = Slot.parse(bytes)
        raise CorruptionError, "unknown array slot tag" unless Slot::TAGS.include?(slot.tag)

        slot
      end

      # Reads and validates one slot at an absolute offset.
      def read_slot(offset)
        parse_slot(read(offset, Slot::SIZE))
      end

      # Follows four index bits per level to find a leaf or empty branch.
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

      # Rejects unknown slots and branch pointers supplied as list elements.
      def validate_slot!(slot)
        raise TypeError, "expected Slot" unless slot.is_a?(Slot)
        raise CorruptionError, "unknown slot tag" unless Slot::TAGS.include?(slot.tag)
        raise InvalidValueError, "index slot is internal to array branches" if slot.tag == :index
      end

      # Runs a write with a checkpoint and restores it on any exception.
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

      # Allocates a header and obtains a writable root block.
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

      # Copies a block only when it lies below the transaction's writable boundary.
      def copy_block(transaction, pointer)
        block = transaction.read_at(pointer, BLOCK_SIZE)
        pointer < transaction.mutable_start ? transaction.append(block) : pointer
      end

      # Copies or allocates the branch path and returns the writable leaf offset.
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
