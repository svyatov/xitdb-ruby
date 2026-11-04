# frozen_string_literal: true

module XitDB
  class Revision
    def initialize(file_id:, trailer_position:, checksum:, index:)
      @file_id = file_id
      @trailer_position = trailer_position
      @checksum = checksum
      @index = index
      freeze
    end

    def resolve(database)
      core = database.core
      current = core.root_cursor
      unless @file_id == core.header.file_id && @trailer_position + Core::Database::TRAILER_SIZE <= current.bound
        raise ForeignRevisionError, "revision does not belong to this file generation"
      end
      trailer = core.read_at(@trailer_position, Core::Database::TRAILER_SIZE, bound: current.bound)
      checksum = trailer.byteslice(17, 8).unpack1("Q>")
      expected = Core::CRC64.call([@file_id, @trailer_position].pack("Q>Q>") + trailer.byteslice(0, 17))
      unless checksum == @checksum && checksum == expected
        raise ForeignRevisionError, "revision trailer proof is no longer valid"
      end
      cursor = Core::Cursor.new(database: core, slot: Core::Slot.parse(trailer.byteslice(0, 9)),
                                bound: @trailer_position + Core::Database::TRAILER_SIZE)
      database.snapshot_from_history(cursor, @index, revision: self)
    rescue CorruptionError, IndexError, InvalidValueError
      raise ForeignRevisionError, "revision history is no longer valid"
    end

    def inspect
      "#<XitDB::Revision>"
    end
  end
end
