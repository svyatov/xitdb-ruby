# frozen_string_literal: true

module XitDB
  module Core
    module Bytes
      CHUNK_SIZE = 64 * 1024

      # Return inline data or its file offset, without materializing a scalar.
      def self.locate(database, slot, bound:)
        unless %i[bytes short_bytes].include?(slot.tag) && !slot.full
          raise InvalidValueError, "stream requires untagged bytes"
        end
        if slot.tag == :short_bytes
          bytes = [slot.value].pack("Q>").split("\0", 2).first || "".b
          return [bytes, bytes.bytesize]
        end

        size = database.read_at(slot.value, 8, bound: bound).unpack1("Q>")
        offset = slot.value + 8
        database.read_at(offset + size, 0, bound: bound)
        [offset, size]
      end

      def self.copy(source, size:, database:, transaction:)
        return database.bytes(source.read(size)) if size <= 8

        offset = transaction.append([size].pack("Q>"))
        remaining = size
        while remaining.positive?
          chunk = source.read([remaining, CHUNK_SIZE].min)
          raise EOFError, "byte source ended before its declared size" if chunk.nil? || chunk.empty?

          transaction.append(chunk)
          remaining -= chunk.bytesize
        end
        Slot.new(tag: :bytes, value: offset)
      end
    end

    class ByteValue
      attr_reader :bytes, :format_tag

      def initialize(bytes, format_tag: nil)
        raise TypeError, "bytes must be a String" unless bytes.is_a?(String)
        unless format_tag.nil? || (format_tag.is_a?(String) && format_tag.bytesize == 2)
          raise ArgumentError, "format_tag must contain two bytes"
        end

        @bytes = bytes.b.freeze
        @format_tag = format_tag&.b&.freeze
        freeze
      end
    end
  end
end
