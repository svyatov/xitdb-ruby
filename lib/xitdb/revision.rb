# frozen_string_literal: true

module XitDB
  # Identifies a history entry and verifies its file generation and trailer.
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
      checksum_bytes = trailer.byteslice(17, 8) || raise(CorruptionError, "truncated revision trailer")
      checksum = checksum_bytes.unpack1("Q>")
      payload = trailer.byteslice(0, 17) || raise(CorruptionError, "truncated revision trailer")
      expected = Core::CRC64.call([@file_id, @trailer_position].pack("Q>Q>") + payload)
      unless checksum == @checksum && checksum == expected
        raise ForeignRevisionError, "revision trailer proof is no longer valid"
      end

      slot_bytes = trailer.byteslice(0, 9) || raise(CorruptionError, "truncated revision trailer")
      cursor = Core::Cursor.new(database: core, slot: Core::Slot.parse(slot_bytes),
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
