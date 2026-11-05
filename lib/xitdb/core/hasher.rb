# frozen_string_literal: true

require "digest"

module XitDB
  module Core
    # Validates the identity and width of a digest implementation.
    class Hasher
      attr_reader :id, :size

      def initialize(id:, size:, &digest)
        raise TypeError, "id must be a String" unless id.is_a?(String)
        raise ArgumentError, "id must contain four bytes" unless id.bytesize == 4
        raise ArgumentError, "digest block is required" unless digest

        @id = id.b.freeze
        @size = Format.integer(size, 1..65_535)
        @digest = digest
        freeze
      end

      def digest(bytes)
        raise TypeError, "bytes must be a String" unless bytes.is_a?(String)

        result = @digest.call(bytes.b.freeze)
        raise TypeError, "digest must return a String" unless result.is_a?(String)
        raise ArgumentError, "digest has incorrect width" unless result.bytesize == size

        result.b.freeze
      end

      def self.sha1
        new(id: "sha1", size: 20) { |bytes| Digest::SHA1.digest(bytes) }
      end

      def self.sha256
        new(id: "sha2", size: 32) { |bytes| Digest::SHA256.digest(bytes) }
      end

      def self.sha384
        new(id: "sha2", size: 48) { |bytes| Digest::SHA384.digest(bytes) }
      end

      def self.sha512
        new(id: "sha2", size: 64) { |bytes| Digest::SHA512.digest(bytes) }
      end
    end
  end
end
