# frozen_string_literal: true

module XitDB
  # Copies logical entries with one iterator per ancestor and no node cache.
  class Conversion
    def initialize(source, destination, transform: nil)
      @source = source
      @destination = destination
      @transform = transform
    end

    def copy(slot, path: [], adapter: nil)
      stack = []
      active = {}
      current = [slot, path]
      selected = adapter
      while true
        if current
          stored, location = current
          current = nil
          adapter = selected || @source.profile.container(stored, context: @source, path: location)
          selected = nil
          if adapter
            identity = [stored.tag, stored.value]
            raise CyclicValueError.new("cyclic stored value", path: location) if active[identity]

            active[identity] = true
            kind = @source.profile.conversion_kind(adapter)
            output = @destination.profile.conversion_container(kind, context: @destination, path: location)
            stack << [identity, location, adapter.each_entry, output, nil]
            result = nil
          else
            bytes = @source.profile.conversion_bytes(stored, context: @source) unless @transform
            if bytes
              result = @destination.profile.copy_conversion_bytes(*bytes, context: @destination, path: location)
            else
              value = @source.profile.decode(stored, context: @source, path: location)
              value = transform(value, location, :value)
              if @source.profile.instance_of?(Profiles::Portable) && !@destination.profile.instance_of?(Profiles::Portable) &&
                  Core::ByteValue === value && value.format_tag == "rb"
                raise UnsupportedValueError.new("portable rb bytes require an explicit transform", path: location)
              end
              result = @destination.profile.encode(value, context: @destination, path: location)
            end
          end
        end
        if result
          return result if stack.empty?

          stack.last[3].assign(stack.last[4], result)
        end
        frame = stack.last
        # Only iterator exhaustion belongs to this rescue. Callback exceptions,
        # including StopIteration, must abort the complete operation.
        entry = begin
          frame[2].next
        rescue StopIteration
          nil
        end
        unless entry
          result = frame[3].slot
          active.delete(frame[0])
          stack.pop
          return result if stack.empty?

          stack.last[3].assign(stack.last[4], result)
          result = nil
          next
        end
        selector, child = entry
        child_path = frame[1] + [selector]
        if %i[map sorted_map set sorted_set].include?(frame[3].kind)
          selector = transform(selector, child_path, :key)
          if frame[3].lookup(selector)
            raise KeyCollisionError.new("converted keys have equal destination identity", path: child_path)
          end
          selector = String.new(selector).freeze if String === selector
          selector = selector.dup.freeze if Time === selector
        end
        frame[4] = selector
        if %i[set sorted_set].include?(frame[3].kind)
          frame[3].assign(selector, Core::Slot.null)
          result = nil
        else
          current = [child, child_path]
        end
      end
    end

    private

    def transform(value, path, role)
      return value unless @transform

      immutable_path = path.map { |part| String === part ? String.new(part).freeze : part }.freeze
      @transform.call(value: value, path: immutable_path, role: role)
    end

    # A bounded byte range, including tagged bytes and Ruby String payloads.
    class ByteSource
      attr_reader :size, :format_tag

      def initialize(context, slot)
        @context = context
        @bound = context.read_bound
        if slot.tag == :short_bytes
          value = context.database.core.read_bytes(slot, bound: @bound)
          @inline = value.bytes
          @size = @inline.bytesize
          @format_tag = value.format_tag
        else
          @size = context.database.core.read_at(slot.value, 8, bound: @bound).unpack1("Q>")
          @offset = slot.value + 8
          context.database.core.read_at(@offset + @size + (slot.full ? 2 : 0), 0, bound: @bound)
          @format_tag = context.database.core.read_at(@offset + @size, 2, bound: @bound) if slot.full
        end
      end

      def read(position, length)
        unless position >= 0 && length >= 0 && position + length <= size
          raise InvalidValueError, "truncated byte payload"
        end
        @inline ? @inline.byteslice(position, length) : @context.database.core.read_at(@offset + position, length, bound: @bound)
      end

      def unsigned(position)
        value = shift = 0
        while true
          part = read(position, 1).getbyte(0)
          position += 1
          value |= (part & 0x7f) << shift
          if part < 0x80
            raise InvalidValueError, "nonminimal unsigned field" if shift.positive? && part.zero?

            return [value, position]
          end
          shift += 7
          raise InvalidValueError, "byte field length exceeds storage range" if shift >= 70
        end
      end

      def slice(position, length)
        read(position + length, 0)
        output = dup
        output.instance_variable_set(:@size, length)
        output.instance_variable_set(:@format_tag, nil)
        if @inline
          output.instance_variable_set(:@inline, @inline.byteslice(position, length))
        else
          output.instance_variable_set(:@offset, @offset + position)
        end
        output
      end

      def portable_encoding
        converter = Encoding::Converter.new(Encoding::UTF_8, Encoding::UTF_16LE)
        each_chunk { |chunk| converter.convert(chunk) }
        converter.finish
        Encoding::UTF_8
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        Encoding::BINARY
      end

      def write_to(context, prefix: "".b, format_tag: @format_tag)
        transaction = context.transaction
        offset = transaction.append([prefix.bytesize + size].pack("Q>"))
        transaction.append(prefix) unless prefix.empty?
        each_chunk { |chunk| transaction.append(chunk) }
        transaction.append(format_tag) if format_tag
        Core::Slot.new(tag: :bytes, value: offset, full: !format_tag.nil?)
      end

      private

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
