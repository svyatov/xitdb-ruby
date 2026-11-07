# frozen_string_literal: true

module XitDB
  module Core
    # A bounded group of slots with an opaque unsigned metadata word.
    # Compaction follows every field while preserving shared references.
    # @api private
    class Record
      # Maximum fields read or written in one record.
      MAX_FIELDS = 32
      # Bytes containing metadata and field count.
      HEADER_SIZE = 8

      # @return [Integer] application-defined unsigned metadata
      attr_reader :metadata
      # @return [Array<Slot>] frozen ordered fields
      attr_reader :fields

      # Validates a bounded record before any storage allocation.
      # @param metadata [Integer] unsigned 32-bit application metadata
      # @param fields [Array<Slot>] at most 32 known slots
      def initialize(metadata:, fields:)
        @metadata = Format.integer!(metadata, 0..((1 << 32) - 1))
        raise ArgumentError, "record exceeds field limit" if fields.size > MAX_FIELDS

        fields.each do |field|
          raise TypeError, "record fields must be slots" unless field.is_a?(Slot)
          raise CorruptionError, "unknown record field tag" unless Slot::TAGS.include?(field.tag)
        end
        @fields = fields.dup.freeze
        freeze
      end

      # Appends a complete record without publishing its descriptor.
      # The owning logical mutation supplies rollback and root publication.
      # @param transaction [Transaction] active writer
      # @param metadata [Integer] unsigned 32-bit application metadata
      # @param fields [Array<Slot>] bounded ordered fields
      # @return [Slot] external record descriptor
      def self.append(transaction, metadata:, fields:)
        transaction.check_active!
        record = new(metadata: metadata, fields: fields)
        bytes = [record.metadata, record.fields.size].pack("NN") + record.fields.map(&:to_bytes).join.b
        Slot.new(tag: :record, value: transaction.append(bytes))
      end

      # Reads a record within its captured boundary, checking its count first.
      # @param database [Database] source storage
      # @param slot [Slot] record descriptor
      # @param bound [Integer] exclusive readable boundary
      # @return [Record] validated immutable fields
      def self.read(database, slot, bound:)
        raise InvalidValueError, "slot does not contain a record" unless slot.tag == :record

        metadata, count = Format.pair(database.read_at(slot.value, HEADER_SIZE, bound: bound), "NN")
        raise CorruptionError, "record exceeds field limit" if count > MAX_FIELDS

        bytes = database.read_at(slot.value + HEADER_SIZE, count * Slot::SIZE, bound: bound)
        fields = Array.new(count) { |index| Slot.parse(Format.slice(bytes, index * Slot::SIZE, Slot::SIZE)) }
        new(metadata: metadata, fields: fields)
      end
    end
  end
end
