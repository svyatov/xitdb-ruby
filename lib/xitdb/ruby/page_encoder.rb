# frozen_string_literal: true

module XitDB
  module Ruby
    # Builds one bounded page without retaining caller-owned values.
    # @api private
    class PageEncoder
      SINGLE_BYTE_UNSIGNED = Array.new(128) { |value| value.chr.freeze }.freeze
      SMALL_INTEGER_CELLS = Array.new(128) { |index| (index + 64).chr.freeze }.freeze
      INSTANCE_OF = Object.instance_method(:instance_of?)
      EQUAL = BasicObject.instance_method(:equal?)
      BYTE_SLICE = String.instance_method(:byteslice)
      private_constant :SINGLE_BYTE_UNSIGNED, :SMALL_INTEGER_CELLS, :INSTANCE_OF, :EQUAL, :BYTE_SLICE

      def initialize(stored: false)
        @stored = stored
        @bytes = +"XP01".b
        @keys = []
      end

      def encode(rows)
        return unless exact?(rows, ::Array)

        # @type var rows: ::Array[top]
        # @type var count: Integer
        count = ::Array.instance_method(:size).bind_call(rows)
        return unless count.between?(1, PageCodec::ROW_LIMIT)

        rows = ::Array.instance_method(:map).bind_call(rows) { |row| row }

        count = rows.size
        return unless write_schema(rows.fetch(0), count)

        count.times do |index|
          row = rows[index]
          return nil unless valid_row?(row)

          # @type var row: Hash[String, top]
          return nil unless encode_row(row)
        end
        @bytes if rows.size == count
      end

      private

      def write_schema(first, count)
        return false unless exact?(first, Hash)

        # @type var first: Hash[String, top]
        # @type var width: Integer
        width = Hash.instance_method(:size).bind_call(first)
        return false if width > PageCodec::FIELD_LIMIT

        @keys = Hash.instance_method(:keys).bind_call(first)
        @bytes << unsigned(count) << unsigned(@keys.size)
        @keys.all? { |key| exact?(key, String) && append(cell(key)) }
      end

      # Bound reflection prevents object hooks from running before validation.
      def exact?(value, klass)
        INSTANCE_OF.bind_call(value, klass)
      end

      def valid_row?(row)
        return false unless exact?(row, Hash)

        # @type var row: Hash[String, top]
        # @type var width: Integer
        width = Hash.instance_method(:size).bind_call(row)
        return false unless width == @keys.size
        return true if @stored

        !Input.hash_defaults?(row)
      end

      # rubocop:disable-next Naming/PredicateMethod -- Appends a row on success.
      def encode_row(row)
        index = 0
        Hash.instance_method(:each_pair).bind_call(row) do |key, value|
          expected = @keys[index]
          return false unless same_key?(key, expected) && append(cell(value))

          index += 1
        end
        index == @keys.size
      end

      def same_key?(key, expected)
        return true if EQUAL.bind_call(key, expected)
        return false unless expected && exact?(key, String)

        # @type var key: String
        # @type var encoding: Encoding
        encoding = String.instance_method(:encoding).bind_call(key)
        encoding == String.instance_method(:encoding).bind_call(expected) &&
          String.instance_method(:==).bind_call(key, expected)
      end

      # rubocop:disable-next Naming/PredicateMethod -- Appends bytes on success.
      def append(bytes)
        return false unless bytes && bytes.bytesize <= PageCodec::PAGE_LIMIT - @bytes.bytesize

        @bytes << bytes
        true
      end

      def cell(value)
        case value
        when nil then "\x00"
        when false then "\x01"
        when true then "\x02"
        when Integer then integer(value)
        when Float then "\x04#{[value].pack("G")}"
        else text(value)
        end
      end

      def integer(value)
        return SMALL_INTEGER_CELLS.fetch(value + 64) if value.between?(-64, 63)
        return unless value.between?(-(1 << 62), (1 << 62) - 1)

        "\x03#{unsigned(value.negative? ? (-value * 2) - 1 : value * 2)}"
      end

      def text(value)
        return unless exact?(value, String)

        # @type var value: String
        value = BYTE_SLICE.bind_call(value, 0, PageCodec::PAGE_LIMIT + 1)
        return if value.bytesize > PageCodec::PAGE_LIMIT

        encoding = value.encoding
        prefix = case encoding
                 when Encoding::UTF_8 then "\x05"
                 when Encoding::US_ASCII then "\x06"
                 when Encoding::BINARY then "\x07"
                 else "\x08#{unsigned(encoding.name.bytesize)}#{encoding.name.b}"
                 end
        prefix + unsigned(value.bytesize) + value.force_encoding(Encoding::BINARY)
      end

      def unsigned(value)
        return SINGLE_BYTE_UNSIGNED.fetch(value) if value < 128

        bytes = +"".b
        while value > 127
          bytes << ((value & 127) | 128)
          value >>= 7
        end
        bytes << value
      end
    end
  end
end
