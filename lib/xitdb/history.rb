# frozen_string_literal: true

module XitDB
  # Enumerates the committed snapshots of a database.
  #
  # A changed transaction appends one root. Index zero selects the oldest root.
  # Reads need an open database handle. Iteration captures one history boundary.
  class History
    include Enumerable

    # Bind history reads to an open database handle.
    # @api private
    # @param database [Database]
    def initialize(database)
      @database = database
    end

    # Read a committed root by position, with the oldest commit at zero.
    # @param index [Integer] negative positions count from the latest commit
    # @return [Snapshot, nil] nil when outside the captured history
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

    # Read a history position and raise when absent.
    # @param index [Integer]
    # @return [Snapshot]
    # @raise [IndexError] if the position is outside history
    def fetch(index)
      self[index] || raise(IndexError, "history index outside history")
    end

    # Count logical commits in the latest published history.
    # @return [Integer]
    def size
      @database.core.with_operation { @database.history_array(@database.core.root_cursor).size }
    end

    # Visit oldest-to-newest snapshots from one captured history boundary.
    #
    # Commits added after iteration starts do not extend this iteration.
    # @yield [snapshot]
    # @yieldparam snapshot [Snapshot]
    # @return [self, Enumerator]
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
