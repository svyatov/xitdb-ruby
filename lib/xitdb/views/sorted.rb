# frozen_string_literal: true

module XitDB
  module Views
    module Sorted
      def rank(key)
        adapter.rank(key)
      end

      def from(key)
        return enum_for(__method__, key) unless block_given?

        each_entries(adapter.each_from(key)) { |*entry| yield(*entry) }
      end

      def from_index(index)
        return enum_for(__method__, index) unless block_given?

        each_entries(adapter.each_from_index(integer_argument(index))) { |*entry| yield(*entry) }
      end

      def page(offset:, limit:)
        check!
        offset = integer_argument(offset)
        limit = integer_argument(limit)
        raise ArgumentError, "negative page limit" if limit.negative?
        return enum_for(__method__, offset: offset, limit: limit) unless block_given?
        return self if limit.zero?

        remaining = limit
        from_index(offset) do |*entry|
          yield(*entry)
          remaining -= 1
          break if remaining.zero?
        end
        self
      end
    end

    class SortedMap < Map
      include Sorted
    end

    class SortedSet < Set
      include Sorted
    end
  end
end
