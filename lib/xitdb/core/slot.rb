# frozen_string_literal: true

module XitDB
  module Core
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
                hash_set counted_hash_map counted_hash_set sorted_map sorted_set sorted_kv_pair record].freeze

      # @!attribute [r] tag
      #   Type tag that determines how to interpret value.
      #   @return [Symbol, Integer]
      # @!attribute [r] value
      #   Unsigned 64-bit scalar bits or record offset.
      #   @return [Integer]
      attr_reader :tag, :value

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
        @value = Format.integer!(value, 0..Format::UINT64_MAX)
        @full = full
        freeze
      end

      # Decodes a descriptor, including its tag and full flag.
      # @param bytes [String] binary input bytes
      # @return [Slot]
      # @raise [CorruptionError] if bytes does not contain exactly nine bytes
      def self.parse(bytes)
        Format.ensure_width!(bytes, SIZE)
        flags = bytes.getbyte(0) || raise(CorruptionError, "missing slot flags")
        value = Format.unsigned(Format.slice(bytes, 1, 8))
        new(tag: flags & 0x7f, value: value, full: flags.anybits?(0x80))
      end

      # Stores a signed 64-bit integer using its unsigned bit pattern.
      # @param value [Integer] integer value
      # @return [Slot]
      # @raise [RangeError] if value exceeds the signed 64-bit range
      def self.int(value)
        Format.integer!(value, -(1 << 63)..((1 << 63) - 1))
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

      # Returns the tag-specific flag stored in the high tag bit.
      # @return [Boolean]
      def full?
        @full
      end

      # Tests whether this slot represents an unused position.
      # @return [Boolean]
      def empty?
        tag == :none && !full?
      end

      # Compares the tag, value, and full flag with another slot.
      # @param other [Object] value to compare
      # @return [Boolean]
      def ==(other)
        other.is_a?(Slot) && tag == other.tag && full? == other.full? && value == other.value
      end

      # Encodes the tag, full flag, and value as nine bytes.
      # @return [String]
      def to_bytes
        code = tag.is_a?(Symbol) ? TAGS.index(tag) : tag
        [code | (full? ? 0x80 : 0), value].pack("CQ>")
      end
    end
  end
end
