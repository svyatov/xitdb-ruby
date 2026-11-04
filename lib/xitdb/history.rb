# frozen_string_literal: true

module XitDB
  class History
    include Enumerable

    def initialize(database)
      @database = database
    end

    def [](index)
      cursor = @database.core.root_cursor
      count = @database.history_array(cursor).size
      raise TypeError, "history index must be an Integer" unless index.is_a?(Integer)

      index += count if index.negative?
      return nil unless index >= 0 && index < count

      @database.snapshot_from_history(cursor, index)
    end

    def fetch(index)
      self[index] || raise(IndexError, "history index outside history")
    end

    def size
      @database.history_array(@database.core.root_cursor).size
    end

    def each
      return enum_for(__method__) unless block_given?

      cursor = @database.core.root_cursor
      @database.history_array(cursor).size.times { |index| yield @database.snapshot_from_history(cursor, index) }
      self
    end
  end
end
