# frozen_string_literal: true

require "digest"

module XitDB
  module Core
    # A fixed-width binary digest algorithm and its stored identity.
    #
    # Hash collections receive digest bytes from their caller.
    # This class checks algorithm output before those bytes reach storage.
    class Hasher
      # @!attribute [r] id
      #   Four-byte hash algorithm identifier.
      #   @return [String]
      # @!attribute [r] size
      #   Declared number of payload or digest bytes.
      #   @return [Integer]
      attr_reader :id, :size

      # Defines a hash algorithm with a fixed identifier and output width.
      # @param id [String] four-byte hash algorithm identifier
      # @param size [Integer] number of bytes
      # @return [Hasher]
      # @yield [bytes] computes one binary digest
      # @yieldparam bytes [String] frozen binary input
      # @yieldreturn [String] exactly size digest bytes
      # @raise [ArgumentError] if id is not four bytes or the block is absent
      # @raise [RangeError] if size is outside 1..65_535
      def initialize(id:, size:, &digest)
        raise TypeError, "id must be a String" unless id.is_a?(String)
        raise ArgumentError, "id must contain four bytes" unless id.bytesize == 4
        raise ArgumentError, "digest block is required" unless digest

        @id = id.b.freeze
        @size = Format.integer(size, 1..65_535)
        @digest = digest
        freeze
      end

      # Calculates a digest and checks its declared width.
      # @param bytes [String] binary input bytes
      # @return [String]
      # @raise [TypeError] if input or digest output is not a String
      # @raise [ArgumentError] if the digest output has the wrong byte count
      def digest(bytes)
        raise TypeError, "bytes must be a String" unless bytes.is_a?(String)

        result = @digest.call(bytes.b.freeze)
        raise TypeError, "digest must return a String" unless result.is_a?(String)
        raise ArgumentError, "digest has incorrect width" unless result.bytesize == size

        result.b.freeze
      end

      # Builds the default 20-byte SHA-1 hasher.
      # @return [Hasher]
      def self.sha1
        new(id: "sha1", size: 20) { |bytes| Digest::SHA1.digest(bytes) }
      end

      # Builds a 32-byte SHA-256 hasher.
      # @return [Hasher]
      def self.sha256
        new(id: "sha2", size: 32) { |bytes| Digest::SHA256.digest(bytes) }
      end

      # Builds a 48-byte SHA-384 hasher.
      # @return [Hasher]
      def self.sha384
        new(id: "sha2", size: 48) { |bytes| Digest::SHA384.digest(bytes) }
      end

      # Builds a 64-byte SHA-512 hasher.
      # @return [Hasher]
      def self.sha512
        new(id: "sha2", size: 64) { |bytes| Digest::SHA512.digest(bytes) }
      end
    end
  end
end
