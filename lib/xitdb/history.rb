# frozen_string_literal: true

module XitDB
  # Enumerates the committed snapshots of a database.
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
      return enum_for(:each) unless block_given?

      # @type var cursor: Core::Cursor?
      cursor = nil
      count = 0
      index = 0
      while cursor.nil? || index < count
        snapshot = @database.core.with_operation do
          captured = cursor
          unless captured
            captured = @database.core.root_cursor
            cursor = captured
            count = @database.history_array(captured).size
          end
          @database.snapshot_from_history(captured, index) if index < count
        end
        break unless snapshot

        yield snapshot
        index += 1
      end
      self
    end
  end
end
