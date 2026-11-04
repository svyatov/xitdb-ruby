# frozen_string_literal: true

module XitDB
  class History
    include Enumerable

    def initialize(database)
      @database = database
    end

    def [](index)
      @database.core.with_operation do
        cursor = @database.core.root_cursor
        count = @database.history_array(cursor).size
        raise TypeError, "history index must be an Integer" unless index.is_a?(Integer)

        index += count if index.negative?
        return nil unless index >= 0 && index < count

        @database.snapshot_from_history(cursor, index)
      end
    end

    def fetch(index)
      self[index] || raise(IndexError, "history index outside history")
    end

    def size
      @database.core.with_operation { @database.history_array(@database.core.root_cursor).size }
    end

    def each
      return enum_for(__method__) unless block_given?

      cursor = count = nil
      index = 0
      while count.nil? || index < count
        snapshot = @database.core.with_operation do
          unless cursor
            cursor = @database.core.root_cursor
            count = @database.history_array(cursor).size
          end
          @database.snapshot_from_history(cursor, index) if index < count
        end
        break unless snapshot

        yield snapshot
        index += 1
      end
      self
    end
  end
end
