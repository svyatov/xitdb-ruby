# frozen_string_literal: true

module XitDB
  module Views
    # A set visited in key order, with rank lookup and bounded pagination.
    class SortedSet < Set
      include Sorted
    end
  end
end
