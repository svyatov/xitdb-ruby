# frozen_string_literal: true

module XitDB
  module Core
    # An indexed slot list backed by a tree with stored subtree counts.
    #
    # Counts locate elements without scanning earlier slots.
    # Split, slice, and concat create detached lists that share unchanged nodes.
    #
    # These structural operations need a writable transaction.
    class LinkedArrayList
      include Enumerable

      # @!attribute [r] cursor
      #   View locating this collection.
      #   @return [Cursor]
      attr_reader :cursor

      # Opens a list whose counted tree supports indexed insertion and removal.
      # @param cursor [Cursor] view locating this collection or value
      # @return [LinkedArrayList]
      def initialize(cursor)
        @cursor = cursor
        @tree = BTree.new(cursor)
      end

      # Returns the number of elements in the tree.
      # @return [Integer]
      def size
        @tree.size
      end

      # Reads a slot by index, counting negative indexes from the end.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [Slot, nil]
      def get(index)
        @tree.at(index)
      end

      # Adds a slot after the final element.
      # @param slot [Slot] stored value or record descriptor
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      def append(slot)
        @tree.insert(size, slot)
        self
      end

      # Replaces an existing element without changing list length.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @param slot [Slot] stored value or record descriptor
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      def put(index, slot)
        replace_child(index, slot)
      end

      # Removes an element and shifts later indexes left.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [Slot, nil]
      def delete_at(index)
        @tree.delete_at(index)
      end

      # Creates a detached list for a range, sharing unchanged tree nodes.
      # @param start [Integer] first selected index; negative indexes count from the end
      # @param length [Integer] number of elements in the selected range
      # @return [LinkedArrayList]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      def slice(start, length)
        self.class.new(@tree.slice(start, length).cursor)
      end

      # Creates detached lists before and from the split index.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [Array<LinkedArrayList>]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      def split(index)
        @tree.split(index).map { |tree| self.class.new(tree.cursor) }
      end

      # Creates a detached list containing this list followed by the other list.
      # @param other [LinkedArrayList] list from the same database to append to this list
      # @return [LinkedArrayList]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [ForeignValueError] if the other list belongs to another database
      def concat(other)
        raise TypeError, "expected LinkedArrayList" unless other.is_a?(LinkedArrayList)

        self.class.new(@tree.concat(BTree.new(other.cursor)).cursor)
      end

      # Replaces an element and forwards ownership and propagation options.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @param slot [Slot] stored value or record descriptor
      # @return [self]
      # @raise [ReadOnlyError] if the collection has no writable transaction
      # @raise [IndexError] if the index or range is outside the allowed list positions
      # @api private
      def replace_child(index, slot, **)
        @tree.replace(index, slot, **)
        self
      end

      # Finds an element view, optionally appending an empty element at the end.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @param create [Boolean] whether to create an empty element when the requested position is absent
      # @return [Cursor, nil]
      def cursor_at(index, create: false)
        slot = get(index)
        if !slot && create
          raise IndexError, "array index outside list" unless index == size

          append(Slot.new)
          slot = get(index)
        end
        return nil unless slot

        index += size if index.negative?
        cursor.array_child(index, slot)
      end

      # Visits all slots in index order.
      # @return [self, Enumerator<Slot>]
      # @yield [slot] receives each visible element
      # @yieldparam slot [Slot] stored element
      # @yieldreturn [Object] ignored
      # @note Without a block, returns an Enumerator.
      def each(&block)
        return enum_for(:each) unless block

        @tree.each_from_index(0, &block)
        self
      end

      # Visits slots from an index, counting negative indexes from the end.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @return [self, Enumerator<Slot>]
      # @yield [slot] receives each visible element
      # @yieldparam slot [Slot] stored element
      # @yieldreturn [Object] ignored
      # @note Without a block, returns an Enumerator.
      def each_from_index(index, &block)
        return enum_for(:each_from_index, index) unless block

        @tree.each_from_index(index, &block)
        self
      end
    end
  end
end
