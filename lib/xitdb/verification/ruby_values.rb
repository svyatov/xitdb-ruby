# frozen_string_literal: true

require_relative "../ruby"
require_relative "payload"

module XitDB
  module Verification
    # Checks Ruby wire values after the graph has validated their physical storage.
    class RubyValues
      def initialize(scan)
        @scan = scan
      end

      def scalar!(slot, offset:, path:)
        return unless slot.full? && Graph::BYTE_TAGS.include?(slot.tag)

        payload = Payload.new(@scan, slot, offset)
        return unless payload.tag == "rb"

        type = scalar_type!(payload, path)
        if [1, 10].include?(type)
          envelope!(payload, codec: type == 10, path: path)
        else
          # The decoder retains the wire, magnitude/hex or decimal text and
          # temporary bignums for reduced fractions and date/time arithmetic.
          @scan.budget.with(:scalar_bytes, (payload.size + 16) * 64) do
            bytes = [1, type].pack("CC") + payload.take(payload.remaining)
            Ruby::Scalars.verify_builtin!(bytes) do |position|
              raise VerificationError.new("invalid Ruby scalar field", check: :scalar,
                                                                       offset: payload.start + position, path: path)
            end
          end
        end
        nil
      rescue ValueError, EncodingError, RangeError, ArgumentError
        raise VerificationError.new("invalid Ruby scalar", check: :scalar, offset: payload&.start || offset, path: path)
      end

      def page!(slot, count:, offset:, path:)
        payload = Payload.new(@scan, slot, offset)
        location = payload.start
        raise InvalidValueError, "Ruby page byte limit exceeded" if payload.size > Ruby::PageCodec::PAGE_LIMIT

        # Source copies, the checksummed body and schema keys all fit this
        # allowance. The page decoder discards cell contents as it advances.
        @scan.budget.with(:scalar_bytes, (payload.size + 64) * 8) do
          Ruby::PageCodec.verify!(payload.take(payload.size), count) do |row, field, position|
            path = @scan.budget.path(path, "row[#{row}]") if row
            path = @scan.budget.path(path, "field[#{field}]") if field
            location = payload.start + position
          end
        end
        nil
      rescue ValueError => e
        if payload && e.is_a?(Ruby::PageDecoder::FieldError)
          location = payload.start + e.position
          path = @scan.budget.path(path, "field[#{e.field}]") if e.field
        end
        raise VerificationError.new(e.message, check: :page, offset: location, path: path)
      end

      private

      def scalar_type!(payload, path)
        offset = payload.start
        raise InvalidValueError, "invalid scalar version" unless payload.take(1) == "\x01"

        offset += 1
        type = payload.take(1).getbyte(0)
        raise InvalidValueError, "unknown scalar type" unless type && (1..10).cover?(type)

        type
      rescue ValueError => e
        raise VerificationError.new(e.message, check: :scalar, offset: offset, path: path)
      end

      # Strings and codecs both start with a UTF-8 name followed by raw bytes.
      # String contents may be invalid in the named encoding. Symbols go through
      # the builtin decoder because their bytes must be valid for interning.
      def envelope!(payload, codec:, path:)
        size = payload.length
        location = payload.start + payload.position
        @scan.budget.with(:scalar_bytes, (size * 4) + 64) do
          name = payload.take(size).force_encoding(Encoding::UTF_8)
          raise InvalidValueError, "invalid name" if name.empty? || !name.valid_encoding?
          raise InvalidValueError, "unknown encoding" unless codec || Encoding.find(name)

          location = payload.start + payload.position
          length = payload.length
          raise InvalidValueError, "trailing payload data" unless length == payload.remaining

          payload.chunks(length) { |_chunk| nil }
          @scan.register_codec!(name) if codec
        end
      rescue ValueError, ArgumentError
        offset = location || (payload.start + 2)
        raise VerificationError.new("invalid Ruby scalar envelope", check: :scalar, offset: offset, path: path)
      end
    end
  end
end
