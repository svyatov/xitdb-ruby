# frozen_string_literal: true

module XitDB
  module Core
    # Storage helpers for byte payloads and optional two-byte application format tags.
    #
    # Small zero-free payloads can fit in a slot. Other payloads use an external record with an unsigned 64-bit length.
    # @api private
    module Bytes
      # Maximum source bytes requested per chunk when appending an external payload.
      CHUNK_SIZE = 64 * 1024

      # Opens an inline or external byte slot without loading its full payload.
      # @param database [Database] database that owns the stored records
      # @param slot [Slot] stored value or record descriptor
      # @param bound [Integer] exclusive upper byte boundary for reads
      # @return [Source]
      # @raise [InvalidValueError] if slot does not describe bytes
      def self.open(database, slot, bound:)
        location, size, format_tag = parse(database, slot, bound)
        Source.new(database, location, size, format_tag, bound)
      end

      # Stores bytes in a slot when they fit, or appends an external payload.
      # @param transaction [Transaction] active destination transaction
      # @param size [Integer] number of bytes
      # @param format_tag [String, nil] optional two-byte application format identifier
      # @param prefix [String] bytes to place before the source payload
      # @param representation [Symbol] :automatic for eligible inline values, or :external
      # @return [Slot]
      # @yield [position, length] provides an exact chunk of source bytes
      # @yieldparam position [Integer] byte offset inside the source, excluding prefix
      # @yieldparam length [Integer] exact number of bytes requested
      # @yieldreturn [String] exactly length bytes
      # @raise [EOFError] if the reader is absent or returns too few bytes
      # @raise [ArgumentError] if the format tag, representation, or chunk length is invalid
      # @raise [RangeError] if the total payload exceeds unsigned 64-bit storage
      def self.append(transaction, size:, format_tag: nil, prefix: "".b, representation: :automatic, &reader)
        transaction.check_active!
        validate_source!(size, prefix, representation, format_tag)
        format_tag = format_tag&.b
        total_size = prefix.bytesize + size
        raise RangeError, "byte payload exceeds unsigned 64-bit size" if total_size >= (1 << 64)

        capacity = format_tag ? 6 : 8
        captured = capture_inline(size, prefix, representation, capacity, &reader)
        if captured && !captured.include?("\0")
          payload = captured.ljust(capacity, "\0") + (format_tag || "")
          return Slot.new(tag: :short_bytes, value: Format.unsigned(payload), full: !format_tag.nil?)
        end

        offset = transaction.append([total_size].pack("Q>"))
        if captured
          transaction.append(captured)
        else
          append_source(transaction, prefix, size, &reader)
        end
        transaction.append(format_tag) if format_tag
        Slot.new(tag: :bytes, value: offset, full: !format_tag.nil?)
      end

      # Checks the source size, prefix, storage mode, and optional format tag.
      def self.validate_source!(size, prefix, representation, format_tag)
        raise TypeError, "size must be an Integer" unless size.is_a?(Integer)
        raise ArgumentError, "size must be nonnegative" if size.negative?
        raise TypeError, "prefix must be a String" unless prefix.is_a?(String)
        raise ArgumentError, "unknown byte representation" unless %i[automatic external].include?(representation)
        return if format_tag.nil? || (format_tag.is_a?(String) && format_tag.bytesize == 2)

        raise ArgumentError, "format_tag must contain two bytes"
      end

      # Reads a small payload once when it might fit inside a slot.
      def self.capture_inline(size, prefix, representation, capacity, &)
        return nil unless representation == :automatic && prefix.bytesize + size <= capacity

        prefix.b + (size.zero? ? "".b : read_chunk(0, size, &))
      end

      # Appends the prefix and source in bounded chunks.
      def self.append_source(transaction, prefix, size, &)
        position = 0
        while position < prefix.bytesize
          chunk = Format.slice(prefix, position, CHUNK_SIZE).b
          transaction.append(chunk)
          position += chunk.bytesize
        end
        position = 0
        while position < size
          length = [size - position, CHUNK_SIZE].min
          transaction.append(read_chunk(position, length, &))
          position += length
        end
      end
      private_class_method :validate_source!, :capture_inline, :append_source

      # Requests one exact chunk and rejects invalid replies.
      def self.read_chunk(position, length)
        chunk = yield(position, length) if block_given?
        raise EOFError, "byte source ended before its declared size" if chunk.nil?
        raise TypeError, "byte source must return a String" unless chunk.is_a?(String)
        raise EOFError, "byte source ended before its declared size" if chunk.bytesize < length
        raise ArgumentError, "byte source returned more than requested" if chunk.bytesize > length

        chunk.b
      end
      private_class_method :read_chunk

      # Finds the payload location, length, and optional two-byte format tag.
      def self.parse(database, slot, bound)
        database.check_open!
        case slot.tag
        when :short_bytes
          payload = [slot.value].pack("Q>")
          capacity = slot.full? ? 6 : 8
          data = (Format.slice(payload, 0, capacity).split("\0", 2).first || "".b).freeze
          tag = Format.slice(payload, 6, 2).freeze if slot.full?
          [data, data.bytesize, tag]
        when :bytes
          size = Format.unsigned(database.read_at(slot.value, 8, bound: bound))
          offset = slot.value + 8
          tail = database.read_at(offset + size, slot.full? ? 2 : 0, bound: bound)
          tag = tail.freeze if slot.full?
          [offset, size, tag]
        else
          raise InvalidValueError, "slot does not contain bytes"
        end
      end
      private_class_method :parse

      # Returns untagged inline bytes or an external offset with its byte count.
      # @param database [Database] database that owns the stored records
      # @param slot [Slot] stored value or record descriptor
      # @param bound [Integer] exclusive upper byte boundary for reads
      # @return [Array(String, Integer), Array(Integer, Integer)]
      # @raise [InvalidValueError] if slot is not untagged bytes
      def self.locate(database, slot, bound:)
        unless %i[bytes short_bytes].include?(slot.tag) && !slot.full?
          raise InvalidValueError, "stream requires untagged bytes"
        end

        location, size = parse(database, slot, bound)
        [location.is_a?(String) ? location.dup : location, size]
      end

      # Copies a declared byte count from an IO-like reader into a slot.
      # @param source [#read] binary reader implementing read(length)
      # @param size [Integer] number of bytes
      # @param database [Database] database that owns the stored records
      # @param transaction [Transaction] active destination transaction
      # @return [Slot]
      # @raise [EOFError] if the source ends before the declared size
      def self.copy(source, size:, database:, transaction:)
        if size <= 8
          bytes = source.read(size)
          raise EOFError, "byte source ended before its declared size" unless bytes

          return database.bytes(bytes)
        end

        append(transaction, size: size, representation: :external) do |_position, length|
          chunk = "".b
          while chunk.bytesize < length
            part = source.read(length - chunk.bytesize)
            raise EOFError, "byte source ended before its declared size" if part.nil? || part.empty?

            chunk << part
          end
          chunk
        end
      end
    end
  end
end

require_relative "bytes/source"
require_relative "byte_value"
