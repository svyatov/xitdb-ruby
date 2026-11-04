# frozen_string_literal: true

module XitDB
  module Core
    class LinkedArrayList
      include Enumerable

      attr_reader :cursor

      def initialize(cursor)
        @cursor = cursor
        @tree = BTree.new(cursor)
      end

      def size
        @tree.size
      end

      def get(index)
        @tree.at(index)
      end

      def append(slot)
        @tree.insert(size, slot)
        self
      end

      def put(index, slot)
        replace_child(index, slot)
      end

      def replace_child(index, slot, **options)
        @tree.replace(index, slot, **options)
        self
      end

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

      def each(&block)
        return enum_for(__method__) unless block

        @tree.each_from_index(0, &block)
        self
      end

      def each_from_index(index, &block)
        return enum_for(__method__, index) unless block

        @tree.each_from_index(index, &block)
        self
      end
    end
  end
end
