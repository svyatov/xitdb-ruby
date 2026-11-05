# frozen_string_literal: true

module XitDB
  module Views
    # Provides array operations backed by the linked positional tree.
    class LinkedArray < Array
      # Capture two read-only slices before and after a split position.
      #
      # The original array is unchanged. Empty sides are valid slices.
      # @param index [Integer] split boundary; negative values count from the end
      # @return [::Array(Slice, Slice)] left and right selections
      # @raise [IndexError] unless the normalized boundary is between zero and size
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
