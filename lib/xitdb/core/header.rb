# frozen_string_literal: true

module XitDB
  module Core
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
        @file_id = Format.integer!(file_id, 0..Format::UINT64_MAX)
        @hash_size = Format.integer!(hash_size, 0..65_535)
        raise TypeError, "hash_id must be a String" unless hash_id.is_a?(String)
        raise ArgumentError, "hash_id must contain four bytes" unless hash_id.bytesize == 4

        @hash_id = hash_id.b.freeze
        @padding = Format.integer!(padding, 0..255)
        freeze
      end

      # Reads and validates the 20-byte database header.
      # @param bytes [String] binary input bytes
      # @return [Header]
      # @raise [CorruptionError] if size or magic bytes are invalid
      # @raise [FormatVersionError] if the format version is unsupported
      def self.parse(bytes)
        Format.ensure_width!(bytes, SIZE)
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
  end
end
