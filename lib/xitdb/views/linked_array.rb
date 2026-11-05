# frozen_string_literal: true

module XitDB
  module Views
    # Provides array operations backed by the linked positional tree.
    class LinkedArray < Array
      def split(index)
        context.read do
          index = integer_argument(index)
          index += size if index.negative?
          raise IndexError, "array split outside list" unless index.between?(0, size)

          [self[0, index], self[index, size - index]]
        end
      end
    end
  end
end
