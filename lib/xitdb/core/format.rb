# frozen_string_literal: true

module XitDB
  module Core
    # Binary decoding checks shared by the storage implementation.
    #
    # A byte offset counts from the start of the file. All stored integers use explicit binary widths.
    # @api private
    module Format
      # Largest integer that fits in an unsigned 64-bit field.
      UINT64_MAX = (1 << 64) - 1

      # Checks that an integer is inside the allowed range.
      # @param value [Object] value to validate as an Integer
      # @param range [Range<Integer>] allowed integer values
      # @return [Integer]
      # @raise [TypeError] if value is not an Integer
      # @raise [RangeError] if value is outside range
      def self.integer(value, range)
        raise TypeError, "expected Integer, got #{value.class}" unless value.is_a?(Integer)
        raise RangeError, "integer outside #{range}" unless range.cover?(value)

        value
      end

      # Checks that a byte string has exactly the required width.
      # @param bytes [String] binary input bytes
      # @param width [Integer] required byte count
      # @return [void]
      # @raise [TypeError] if bytes is not a String
      # @raise [CorruptionError] if the width differs
      def self.width(bytes, width)
        raise TypeError, "expected String, got #{bytes.class}" unless bytes.is_a?(String)
        raise CorruptionError, "expected #{width} bytes, got #{bytes.bytesize}" unless bytes.bytesize == width
      end

      # Reads a byte range and rejects a missing slice.
      # @param bytes [String] binary input to slice
      # @param offset [Integer, Range] byte index or range within bytes
      # @param length [Integer, nil] byte count; nil selects one byte for an integer offset
      # @return [String]
      # @raise [CorruptionError] if the slice starts outside the payload
      def self.slice(bytes, offset, length = nil)
        result = if offset.is_a?(Range)
                   bytes.byteslice(offset)
                 else
                   bytes.byteslice(offset, length || 1)
                 end
        raise CorruptionError, "byte slice exceeds payload" unless result

        result
      end

      # Decodes an unsigned 64-bit integer in big-endian order.
      # @param bytes [String] binary input bytes
      # @return [Integer]
      def self.unsigned(bytes)
        value = bytes.unpack1("Q>")
        raise CorruptionError, "invalid unsigned integer" unless value.is_a?(Integer)

        value
      end

      # Decodes packed integers and rejects incomplete values.
      # @param bytes [String] binary input bytes
      # @param format [String] Ruby unpack format for the packed integers
      # @return [Array<Integer>]
      def self.integers(bytes, format)
        bytes.unpack(format).map do |value|
          raise CorruptionError, "invalid integer payload" unless value.is_a?(Integer)

          value
        end
      end

      # Decodes the first two integers in a packed record.
      # @param bytes [String] binary input bytes
      # @param format [String] Ruby unpack format for the packed integers
      # @return [Array(Integer, Integer)]
      def self.pair(bytes, format)
        values = integers(bytes, format)
        [values.fetch(0), values.fetch(1)]
      end
    end

    # The immutable file profile stored in the first 20 bytes.
    #
    # The profile records the format version, file identity, and hash algorithm identity and width.
    class Header
      # Width of the encoded file header in bytes.
      SIZE = 20
      # Supported version of the binary database format.
      VERSION = 1

      # @!attribute [r] file_id
      #   Unsigned 64-bit file identifier.
      #   @return [Integer]
      # @!attribute [r] hash_id
      #   Four-byte hash algorithm identifier.
      #   @return [String]
      # @!attribute [r] hash_size
      #   Digest width in bytes.
      #   @return [Integer]
      attr_reader :file_id, :hash_id, :hash_size

      # Builds a frozen header identifying the file and its hash format.
      # @param file_id [Integer] unsigned 64-bit file identifier
      # @param hash_id [String] four-byte hash algorithm identifier
      # @param hash_size [Integer] number of bytes in each stored digest
      # @param padding [Integer] header padding byte, from 0 through 255
      # @return [Header]
      # @raise [ArgumentError] if hash_id is not four bytes
      # @raise [TypeError] if an argument has the wrong type
      # @raise [RangeError] if a numeric field exceeds its encoded range
      def initialize(file_id:, hash_id:, hash_size:, padding: 0)
        @file_id = Format.integer(file_id, 0..Format::UINT64_MAX)
        @hash_size = Format.integer(hash_size, 0..65_535)
        raise TypeError, "hash_id must be a String" unless hash_id.is_a?(String)
        raise ArgumentError, "hash_id must contain four bytes" unless hash_id.bytesize == 4

        @hash_id = hash_id.b.freeze
        @padding = Format.integer(padding, 0..255)
        freeze
      end

      # Reads and validates the 20-byte database header.
      # @param bytes [String] binary input bytes
      # @return [Header]
      # @raise [CorruptionError] if size or magic bytes are invalid
      # @raise [FormatVersionError] if the format version is unsupported
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

      # Encodes the header in the database's binary format.
      # @return [String]
      def to_bytes
        ["xit", @padding, VERSION, hash_size, hash_id, file_id].pack("a3Cnn a4Q>")
      end
    end

    # An immutable nine-byte descriptor for one database value.
    #
    # The tag says how to read value: it holds scalar bits or the offset of another record.
    #
    # The full flag has a tag-specific meaning, such as explicit null or a byte format tag.
    #
    # Use the scalar factory methods to encode numbers; value itself always holds unsigned 64-bit bits.
    #
    # @example Build slots for scalar values
    #   Slot.int(-3).tag       # => :int
    #   Slot.uint(3).value     # => 3
    #   Slot.null.empty?      # => false
    #   Slot.new.empty?       # => true
    class Slot
      # Width of a slot: one tag byte and eight value bytes.
      SIZE = 9
      # Known symbolic tags, ordered by their seven-bit numeric storage code.
      TAGS = %i[none index array_list linked_array_list hash_map kv_pair bytes short_bytes uint int float
                hash_set counted_hash_map counted_hash_set sorted_map sorted_set sorted_kv_pair].freeze

      # @!attribute [r] tag
      #   Type tag that determines how to interpret value.
      #   @return [Symbol, Integer]
      # @!attribute [r] value
      #   Unsigned 64-bit scalar bits or record offset.
      #   @return [Integer]
      # @!attribute [r] full
      #   Tag-specific flag stored in the high tag bit.
      #   @return [Boolean]
      attr_reader :tag, :value, :full

      # Builds a frozen nine-byte value descriptor.
      # @param tag [Symbol, Integer] storage type tag
      # @param value [Integer] integer value
      # @param full [Boolean] tag-dependent flag stored in the high tag bit
      # @return [Slot]
      # @raise [ArgumentError] if the tag cannot be encoded in seven bits
      # @raise [TypeError] if value or full has the wrong type
      # @raise [RangeError] if value exceeds unsigned 64-bit storage
      def initialize(tag: :none, value: 0, full: false)
        code = tag.is_a?(Symbol) ? TAGS.index(tag) : tag
        raise ArgumentError, "invalid slot tag: #{tag.inspect}" unless code.is_a?(Integer) && (0..127).cover?(code)
        raise TypeError, "full must be true or false" unless full.equal?(true) || full.equal?(false)

        @tag = TAGS[code] || code
        @value = Format.integer(value, 0..Format::UINT64_MAX)
        @full = full
        freeze
      end

      # Decodes a descriptor, including its tag and full flag.
      # @param bytes [String] binary input bytes
      # @return [Slot]
      # @raise [CorruptionError] if bytes does not contain exactly nine bytes
      def self.parse(bytes)
        Format.width(bytes, SIZE)
        flags = bytes.getbyte(0) || raise(CorruptionError, "missing slot flags")
        value = Format.unsigned(Format.slice(bytes, 1, 8))
        new(tag: flags & 0x7f, value: value, full: flags.anybits?(0x80))
      end

      # Stores a signed 64-bit integer using its unsigned bit pattern.
      # @param value [Integer] integer value
      # @return [Slot]
      # @raise [RangeError] if value exceeds the signed 64-bit range
      def self.int(value)
        Format.integer(value, -(1 << 63)..((1 << 63) - 1))
        new(tag: :int, value: value & Format::UINT64_MAX)
      end

      # Stores an unsigned 64-bit integer directly in a slot.
      # @param value [Integer] integer value
      # @return [Slot]
      # @raise [RangeError] if value exceeds the unsigned 64-bit range
      def self.uint(value)
        new(tag: :uint, value: value)
      end

      # Stores the bit pattern of a Ruby Float in a slot.
      # @param value [Float] floating-point value to encode
      # @return [Slot]
      # @raise [TypeError] if value is not a Float
      def self.float(value)
        raise TypeError, "expected Float, got #{value.class}" unless value.is_a?(Float)

        new(tag: :float, value: Format.unsigned([value].pack("G")))
      end

      # Builds an explicit null slot, distinct from an empty slot.
      # @return [Slot]
      def self.null
        new(full: true)
      end

      # Tests whether this slot represents an unused position.
      # @return [Boolean]
      def empty?
        tag == :none && !full
      end

      # Compares the tag, value, and full flag with another slot.
      # @param other [Object] value to compare
      # @return [Boolean]
      def ==(other)
        other.is_a?(Slot) && tag == other.tag && full == other.full && value == other.value
      end

      # Encodes the tag, full flag, and value as nine bytes.
      # @return [String]
      def to_bytes
        code = tag.is_a?(Symbol) ? TAGS.index(tag) : tag
        [code | (full ? 0x80 : 0), value].pack("CQ>")
      end
    end
  end
end
