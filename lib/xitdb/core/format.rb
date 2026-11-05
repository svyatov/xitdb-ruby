# frozen_string_literal: true

module XitDB
  module Core
    # Validates and decodes the binary storage format.
    module Format
      UINT64_MAX = (1 << 64) - 1

      def self.integer(value, range)
        raise TypeError, "expected Integer, got #{value.class}" unless value.is_a?(Integer)
        raise RangeError, "integer outside #{range}" unless range.cover?(value)

        value
      end

      def self.width(bytes, width)
        raise TypeError, "expected String, got #{bytes.class}" unless bytes.is_a?(String)
        raise CorruptionError, "expected #{width} bytes, got #{bytes.bytesize}" unless bytes.bytesize == width
      end

      def self.slice(bytes, offset, length = nil)
        result = if offset.is_a?(Range)
                   bytes.byteslice(offset)
                 else
                   bytes.byteslice(offset, length || 1)
                 end
        raise CorruptionError, "byte slice exceeds payload" unless result

        result
      end

      def self.unsigned(bytes)
        value = bytes.unpack1("Q>")
        raise CorruptionError, "invalid unsigned integer" unless value.is_a?(Integer)

        value
      end

      def self.integers(bytes, format)
        bytes.unpack(format).map do |value|
          raise CorruptionError, "invalid integer payload" unless value.is_a?(Integer)

          value
        end
      end

      def self.pair(bytes, format)
        values = integers(bytes, format)
        [values.fetch(0), values.fetch(1)]
      end
    end

    # The immutable database format header.
    class Header
      SIZE = 20
      VERSION = 1

      attr_reader :file_id, :hash_id, :hash_size

      def initialize(file_id:, hash_id:, hash_size:, padding: 0)
        @file_id = Format.integer(file_id, 0..Format::UINT64_MAX)
        @hash_size = Format.integer(hash_size, 0..65_535)
        raise TypeError, "hash_id must be a String" unless hash_id.is_a?(String)
        raise ArgumentError, "hash_id must contain four bytes" unless hash_id.bytesize == 4

        @hash_id = hash_id.b.freeze
        @padding = Format.integer(padding, 0..255)
        freeze
      end

      def self.parse(bytes)
        Format.width(bytes, SIZE)
        magic = Format.slice(bytes, 0, 3)
        padding = bytes.getbyte(3) || raise(CorruptionError, "missing header padding")
        version, hash_size = Format.pair(Format.slice(bytes, 4, 4), "nn")
        hash_id = Format.slice(bytes, 8, 4)
        file_id = Format.unsigned(Format.slice(bytes, 12, 8))
        raise CorruptionError, "invalid xitdb magic number" unless magic == "xit"
        raise FormatVersionError, "unsupported xitdb format version #{version}" unless version == VERSION

        new(file_id: file_id, hash_id: hash_id, hash_size: hash_size, padding: padding)
      end

      def to_bytes
        ["xit", @padding, VERSION, hash_size, hash_id, file_id].pack("a3Cnn a4Q>")
      end
    end

    # An immutable tagged value or record reference.
    class Slot
      SIZE = 9
      TAGS = %i[none index array_list linked_array_list hash_map kv_pair bytes short_bytes uint int float
                hash_set counted_hash_map counted_hash_set sorted_map sorted_set sorted_kv_pair].freeze

      attr_reader :tag, :value, :full

      def initialize(tag: :none, value: 0, full: false)
        code = tag.is_a?(Symbol) ? TAGS.index(tag) : tag
        raise ArgumentError, "invalid slot tag: #{tag.inspect}" unless code.is_a?(Integer) && (0..127).cover?(code)
        raise TypeError, "full must be true or false" unless full.equal?(true) || full.equal?(false)

        @tag = TAGS[code] || code
        @value = Format.integer(value, 0..Format::UINT64_MAX)
        @full = full
        freeze
      end

      def self.parse(bytes)
        Format.width(bytes, SIZE)
        flags = bytes.getbyte(0) || raise(CorruptionError, "missing slot flags")
        value = Format.unsigned(Format.slice(bytes, 1, 8))
        new(tag: flags & 0x7f, value: value, full: flags.anybits?(0x80))
      end

      def self.int(value)
        Format.integer(value, -(1 << 63)..((1 << 63) - 1))
        new(tag: :int, value: value & Format::UINT64_MAX)
      end

      def self.uint(value)
        new(tag: :uint, value: value)
      end

      def self.float(value)
        raise TypeError, "expected Float, got #{value.class}" unless value.is_a?(Float)

        new(tag: :float, value: Format.unsigned([value].pack("G")))
      end

      def self.null
        new(full: true)
      end

      def empty?
        tag == :none && !full
      end

      def ==(other)
        other.is_a?(Slot) && tag == other.tag && full == other.full && value == other.value
      end

      def to_bytes
        code = tag.is_a?(Symbol) ? TAGS.index(tag) : tag
        [code | (full ? 0x80 : 0), value].pack("CQ>")
      end
    end
  end
end
