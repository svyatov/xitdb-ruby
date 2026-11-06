# frozen_string_literal: true

require "monitor"

require_relative "store"

module XitDB
  module Core
    # A synchronized byte store backed by a private binary string.
    #
    # Offsets use bytes, starting at zero. Closing discards all data; sync has no persistent storage to update.
    class MemoryStore
      include Store

      # @!attribute [r] storage_identity
      #   Identity shared by handles referring to the same underlying storage.
      #   @return [Object, Array<Integer>]
      attr_reader :storage_identity

      # Copies initial bytes into a writable in-memory store.
      # @param bytes [String] binary input bytes
      # @return [MemoryStore]
      def initialize(bytes = "".b)
        string(bytes)
        @bytes = bytes.b
        @storage_identity = Object.new.freeze
        initialize_state
      end

      # Reports whether writes are disabled.
      # @return [Boolean]
      def readonly?
        false
      end

      private

      # Counts the bytes held by the in-memory store.
      def store_length
        @bytes.bytesize
      end

      # Reads a validated range from the binary string.
      def read_bytes(offset, length)
        Format.slice(@bytes, offset, length)
      end

      # Replaces a range, filling any gap before it with zero bytes.
      def write_bytes(offset, bytes)
        @bytes << ("\0".b * (offset - store_length)) if offset > store_length
        @bytes[offset, bytes.bytesize] = bytes
      end

      # Shrinks or extends the binary string to the requested length.
      def truncate_bytes(length)
        if length < store_length
          @bytes = Format.slice(@bytes, 0, length)
        else
          @bytes << ("\0".b * (length - store_length))
        end
      end

      # Completes a flush without work because memory has no write buffer.
      def flush_bytes; end

      # Completes synchronization without work because this store has no disk file.
      def sync_bytes; end

      # Releases all bytes held by the in-memory store.
      def close_bytes
        @bytes.clear
      end
    end
  end
end
