# frozen_string_literal: true

module XitDB
  module Ruby
    # Validates every cell while allocating only requested row values.
    # @api private
    class PageDecoder
      def initialize(bytes, expected)
        raise TypeError, "page must be a String" unless Object.instance_method(:is_a?).bind_call(bytes, String)

        # @type var source: String
        source = String.instance_method(:byteslice).bind_call(bytes, 0, PageCodec::PAGE_LIMIT + 1)
        @bytes = source.b
        raise InvalidValueError, "Ruby page byte limit exceeded" if @bytes.bytesize > PageCodec::PAGE_LIMIT

        @position = 0
        raise InvalidValueError, "invalid Ruby page magic" unless take(4) == "XP01"

        @count = unsigned
        width = unsigned
        validate_count!(@count, width, expected)
        @keys = schema(width)
      end

      def page
        rows = ::Array.new(@count) { read_row }
        finish!
        rows
      end

      def row(index)
        raise IndexError, "row outside Ruby page" if index >= @count

        result = nil
        @count.times do |position|
          if position == index
            result = read_row
          else
            @keys.size.times { skip_cell }
          end
        end
        finish!
        result || raise(IndexError, "row outside Ruby page")
      end

      private

      def validate_count!(count, width, expected)
        unless count.between?(1, PageCodec::ROW_LIMIT) && width <= PageCodec::FIELD_LIMIT
          raise InvalidValueError, "invalid Ruby page count"
        end
        return if BasicObject.instance_method(:equal?).bind_call(expected, nil)

        unless Object.instance_method(:is_a?).bind_call(expected, Integer)
          raise TypeError, "expected row count must be an Integer"
        end
        raise InvalidValueError, "Ruby page row count mismatch" unless expected == count
      end

      def schema(width)
        # @type var seen: Hash[String, bool]
        seen = {}
        ::Array.new(width) do
          key = cell
          raise InvalidValueError, "Ruby page key must be a String" unless key.is_a?(String)
          raise InvalidValueError, "duplicate Ruby page key" if seen.key?(key)

          key = -key
          seen[key] = true
          key
        end
      end

      def read_row
        @keys.to_h { |key| [key, cell] }
      end

      def cell
        tag = byte
        case tag
        when 0 then nil
        when 1 then false
        when 2 then true
        when 3
          value = unsigned
          (value >> 1) ^ -(value & 1)
        when 4 then take(8).unpack1("G")
        else
          encoding = string_encoding(tag)
          take(unsigned).force_encoding(encoding)
        end
      end

      def skip_cell
        tag = byte
        case tag
        when 0, 1, 2 then nil
        when 3 then unsigned
        when 4 then advance!(8)
        else
          string_encoding(tag)
          advance!(unsigned)
        end
      end

      def string_encoding(tag)
        case tag
        when 5 then Encoding::UTF_8
        when 6 then Encoding::US_ASCII
        when 7 then Encoding::BINARY
        when 8 then named_encoding
        else raise InvalidValueError, "unknown Ruby page tag"
        end
      end

      def named_encoding
        length = unsigned
        raise InvalidValueError, "invalid Ruby page encoding name" unless length.between?(1, 127)

        name = take(length)
        encoding = Encoding.find(name)
        unless encoding && encoding.name == name && ![Encoding::UTF_8, Encoding::US_ASCII, Encoding::BINARY].include?(encoding)
          raise InvalidValueError, "noncanonical Ruby page encoding"
        end

        encoding
      rescue ArgumentError
        raise InvalidValueError, "invalid Ruby page encoding"
      end

      def unsigned
        value = 0
        (0..63).step(7) do |shift|
          part = byte
          raise InvalidValueError, "Ruby page integer overflow" if shift == 63 && part > 1

          value |= (part & 127) << shift
          next unless part < 128

          raise InvalidValueError, "noncanonical Ruby page integer" if shift.positive? && part.zero?

          return value
        end
        raise InvalidValueError, "Ruby page integer overflow"
      end

      def byte
        value = @bytes.getbyte(@position)
        raise InvalidValueError, "truncated Ruby page" unless value

        @position += 1
        value
      end

      def take(length)
        position = @position
        advance!(length)
        @bytes.byteslice(position, length) || raise(InvalidValueError, "truncated Ruby page")
      end

      def advance!(length)
        raise InvalidValueError, "truncated Ruby page" if length > @bytes.bytesize - @position

        @position += length
      end

      def finish!
        raise InvalidValueError, "trailing Ruby page bytes" unless @position == @bytes.bytesize
      end
    end
  end
end
