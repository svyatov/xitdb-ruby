# frozen_string_literal: true

module XitDB
  module Core
    # Reads and writes inline or external byte payloads.
    module Bytes
      CHUNK_SIZE = 64 * 1024

      # A bounded reader for one immutable byte payload.
      class Source
        attr_reader :size, :format_tag

        def initialize(database, location, size, format_tag, bound)
          @database = database
          @location = location
          @size = size
          @format_tag = format_tag
          @bound = bound
          freeze
        end

        def read(position, length)
          @database.check_open!
          unless position.is_a?(Integer) && length.is_a?(Integer)
            raise TypeError, "byte positions and lengths must be Integers"
          end
          if position.negative? || length.negative? || position + length > size
            raise InvalidValueError, "truncated byte payload"
          end

          location = @location
          if location.is_a?(String)
            Format.slice(location, position, length)
          else
            @database.read_at(location + position, length, bound: @bound)
          end
        end
      end
      private_constant :Source

      def self.open(database, slot, bound:)
        location, size, format_tag = parse(database, slot, bound)
        Source.new(database, location, size, format_tag, bound)
      end

      def self.append(transaction, size:, format_tag: nil, prefix: "".b, representation: :automatic, &reader)
        transaction.check_active!
        validate_source(size, prefix, representation, format_tag)
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

      def self.validate_source(size, prefix, representation, format_tag)
        raise TypeError, "size must be an Integer" unless size.is_a?(Integer)
        raise ArgumentError, "size must be nonnegative" if size.negative?
        raise TypeError, "prefix must be a String" unless prefix.is_a?(String)
        raise ArgumentError, "unknown byte representation" unless %i[automatic external].include?(representation)
        return if format_tag.nil? || (format_tag.is_a?(String) && format_tag.bytesize == 2)

        raise ArgumentError, "format_tag must contain two bytes"
      end

      def self.capture_inline(size, prefix, representation, capacity, &)
        return nil unless representation == :automatic && prefix.bytesize + size <= capacity

        prefix.b + (size.zero? ? "".b : read_chunk(0, size, &))
      end

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
      private_class_method :validate_source, :capture_inline, :append_source

      def self.read_chunk(position, length)
        chunk = yield(position, length) if block_given?
        raise EOFError, "byte source ended before its declared size" if chunk.nil?
        raise TypeError, "byte source must return a String" unless chunk.is_a?(String)
        raise EOFError, "byte source ended before its declared size" if chunk.bytesize < length
        raise ArgumentError, "byte source returned more than requested" if chunk.bytesize > length

        chunk.b
      end
      private_class_method :read_chunk

      def self.parse(database, slot, bound)
        database.check_open!
        case slot.tag
        when :short_bytes
          payload = [slot.value].pack("Q>")
          capacity = slot.full ? 6 : 8
          data = (Format.slice(payload, 0, capacity).split("\0", 2).first || "".b).freeze
          tag = Format.slice(payload, 6, 2).freeze if slot.full
          [data, data.bytesize, tag]
        when :bytes
          size = Format.unsigned(database.read_at(slot.value, 8, bound: bound))
          offset = slot.value + 8
          tail = database.read_at(offset + size, slot.full ? 2 : 0, bound: bound)
          tag = tail.freeze if slot.full
          [offset, size, tag]
        else
          raise InvalidValueError, "slot does not contain bytes"
        end
      end
      private_class_method :parse

      # Return inline data or its file offset, without materializing a scalar.
      def self.locate(database, slot, bound:)
        unless %i[bytes short_bytes].include?(slot.tag) && !slot.full
          raise InvalidValueError, "stream requires untagged bytes"
        end

        location, size = parse(database, slot, bound)
        [location.is_a?(String) ? location.dup : location, size]
      end

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

    # An immutable byte payload and its optional format tag.
    class ByteValue
      attr_reader :bytes, :format_tag

      def initialize(bytes, format_tag: nil)
        raise TypeError, "bytes must be a String" unless bytes.is_a?(String)
        unless format_tag.nil? || (format_tag.is_a?(String) && format_tag.bytesize == 2)
          raise ArgumentError, "format_tag must contain two bytes"
        end

        @bytes = bytes.b.freeze
        @format_tag = format_tag&.b&.freeze
        freeze
      end
    end
  end
end
