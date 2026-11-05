# frozen_string_literal: true

module XitDB
  # Identifies a history entry and verifies its file generation and trailer.
  #
  # Obtain this opaque token from {Snapshot#revision}. Pass it to
  # {Database#snapshot} to read that state again through a compatible handle.
  # A token is not a portable index for another database or file generation.
  class Revision
    # Record a history position and the proof of its file generation.
    # @api private
    # @param file_id [Integer] file's random identity
    # @param trailer_position [Integer] byte offset of the commit record
    # @param checksum [Integer] integrity proof for that record
    # @param index [Integer] logical history position
    def initialize(file_id:, trailer_position:, checksum:, index:)
      @file_id = file_id
      @trailer_position = trailer_position
      @checksum = checksum
      @index = index
      freeze
    end

    # Validate the saved proof and read the corresponding root.
    # @api private
    # @param database [Database]
    # @return [Snapshot]
    # @raise [ForeignRevisionError] if the file identity or saved commit proof differs
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

    # Describe the token without exposing its internal proof fields.
    # @return [String]
    def inspect
      "#<XitDB::Revision>"
    end
  end
end
