# frozen_string_literal: true

module XitDB
  class Conversion
    # A bounded byte range, including tagged bytes and Ruby String payloads.
    class ByteSource
      # Captured byte length and optional format label for this source.
      #
      # @!attribute [r] size
      #   Number of bytes visible through this source.
      #   @return [Integer]
      # @!attribute [r] format_tag
      #   Optional two-byte label attached to the stored byte value.
      #   @return [String, nil]
      attr_reader :size, :format_tag

      # Capture a bounded byte source without loading its payload.
      # @param context [Context]
      # @param slot [Core::Slot]
      def initialize(context, slot)
        @source = Core::Bytes.open(context.database.core, slot, bound: context.read_bound)
        @start = 0
        @size = @source.size
        @format_tag = @source.format_tag
      end

      # Read a checked byte range relative to this source's start.
      # @param position [Integer]
      # @param length [Integer]
      # @return [String]
      # @raise [InvalidValueError] if the requested range exceeds this source
      def read(position, length)
        unless position >= 0 && length >= 0 && position + length <= size
          raise InvalidValueError, "truncated byte payload"
        end

        @source.read(@start + position, length)
      end

      # Decode a minimal base-128 unsigned integer and report the next byte position.
      # @param position [Integer]
      # @return [Array(Integer, Integer)] integer and next position
      def unsigned(position)
        value = shift = 0
        while true
          part = read(position, 1).getbyte(0) || raise(InvalidValueError, "truncated byte payload")
          position += 1
          value |= (part & 0x7f) << shift
          if part < 0x80
            raise InvalidValueError, "nonminimal unsigned field" if shift.positive? && part.zero?

            break
          end
          shift += 7
          raise InvalidValueError, "byte field length exceeds storage range" if shift >= 70
        end
        [value, position]
      end

      # Create a bounded subsource that shares the same underlying storage.
      # @param position [Integer]
      # @param length [Integer]
      # @return [ByteSource]
      def slice(position, length)
        read(position + length, 0)
        output = dup
        output.instance_variable_set(:@size, length)
        output.instance_variable_set(:@format_tag, nil)
        output.instance_variable_set(:@start, @start + position)
        output
      end

      # Validate UTF-8 in chunks and select UTF-8 or binary for a portable byte payload.
      # @return [Encoding]
      def portable_encoding
        converter = Encoding::Converter.new(Encoding::UTF_8, Encoding::UTF_16LE)
        each_chunk { |chunk| converter.convert(chunk) }
        converter.finish
        Encoding::UTF_8
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        Encoding::BINARY
      end

      # Append this source to a destination transaction in bounded chunks.
      # @param context [Context]
      # @param prefix [String] optional bytes preceding the source payload
      # @param format_tag [String, nil]
      # @return [Core::Slot]
      def write_to(context, prefix: "".b, format_tag: @format_tag)
        Core::Bytes.append(context.writable_transaction!, size: size, prefix: prefix, format_tag: format_tag,
                                                          representation: :external) do |position, length|
          read(position, length)
        end
      end

      private

      # Visit bounded pieces without retaining the complete byte value.
      # @yield [chunk]
      # @yieldparam chunk [String]
      # @return [void]
      def each_chunk
        position = 0
        while position < size
          chunk = read(position, [size - position, Core::Bytes::CHUNK_SIZE].min)
          yield chunk
          position += chunk.bytesize
        end
      end
    end
  end
end
