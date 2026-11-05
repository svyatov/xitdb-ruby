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
      # @type var stack: ::Array[conversion_frame]
      stack = []
      # @type var active: ::Hash[[Symbol, Integer], bool]
      active = {}
      # @type var current: [Core::Slot, path]?
      current = [slot, path]
      selected = adapter
      # @type var result: Core::Slot?
      result = nil
      while true # rubocop:disable Style/InfiniteLoop -- Callback StopIteration must propagate.
        if current
          result = begin_value(current[0], current[1], selected, stack, active)
          current = nil
          selected = nil
        end
        if result
          break if stack.empty?

          assign_parent(stack, result)
        end
        frame = stack.last || raise(CorruptionError, "missing conversion frame")
        entry = next_entry(frame)
        if entry
          current = select_child(frame, entry)
        else
          result = finish_frame(frame, stack, active)
          break if stack.empty?
        end
        result = nil
      end
      result || raise(CorruptionError, "conversion produced no value")
    end

    private

    def begin_value(stored, location, selected, stack, active)
      adapter = selected || @source.profile.container(stored, context: @source, path: location)
      return copy_scalar(stored, location) unless adapter

      # @type var identity: [Symbol, Integer]
      identity = [stored.tag, stored.value]
      raise CyclicValueError.new("cyclic stored value", path: location) if active[identity]

      active[identity] = true
      kind = @source.profile.conversion_kind(adapter)
      output = @destination.profile.conversion_container(kind, context: @destination, path: location)
      stack << [identity, location, adapter.each_entry, output, nil]
      nil
    end

    def copy_scalar(stored, location)
      bytes = @source.profile.conversion_bytes(stored, context: @source) unless @transform
      if bytes
        return @destination.profile.copy_conversion_bytes(bytes[0], bytes[1], context: @destination, path: location)
      end

      value = @source.profile.decode(stored, context: @source, path: location)
      value = transform(value, location, :value)
      if @source.profile.instance_of?(Profiles::Portable) && !@destination.profile.instance_of?(Profiles::Portable)
        case value
        when Core::ByteValue
          if value.format_tag == "rb"
            raise UnsupportedValueError.new("portable rb bytes require an explicit transform", path: location)
          end
        end
      end
      @destination.profile.encode(value, context: @destination, path: location)
    end

    def assign_parent(stack, stored)
      parent = stack.last || raise(CorruptionError, "missing conversion parent")
      parent[3].assign(parent[4], stored)
    end

    def finish_frame(frame, stack, active)
      stored = frame[3].slot
      active.delete(frame[0])
      stack.pop
      assign_parent(stack, stored) unless stack.empty?
      stored
    end

    # Callback StopIteration must abort the operation, so rescue only #next.
    def next_entry(frame)
      frame[2].next
    rescue StopIteration
      nil
    end

    def select_child(frame, entry)
      selector, child = entry
      child_path = frame[1] + [selector]
      if %i[map sorted_map set sorted_set].include?(frame[3].kind)
        selector = transform_key(selector, child_path)
        if frame[3].lookup(selector)
          raise KeyCollisionError.new("converted keys have equal destination identity", path: child_path)
        end

        selector = case selector
                   when String then String.new(selector).freeze
                   when Time then selector.dup.freeze
                   else selector
                   end
      end
      frame[4] = selector
      if %i[set sorted_set].include?(frame[3].kind)
        frame[3].assign(selector, Core::Slot.null)
        nil
      else
        [child, child_path]
      end
    end

    def transform_key(value, path)
      converted = transform(value, path, :key)
      case converted
      when String, Integer, Float, Time, Symbol, TrueClass, FalseClass, NilClass, UInt
        converted
      else
        raise UnsupportedValueError.new("unsupported converted key", path: path)
      end
    end

    def transform(value, path, role)
      callback = @transform
      return value unless callback

      immutable_path = path.map do |part|
        case part
        when String then String.new(part).freeze
        else part
        end
      end.freeze
      callback.call(value: value, path: immutable_path, role: role)
    end

    # A bounded byte range, including tagged bytes and Ruby String payloads.
    class ByteSource
      attr_reader :size, :format_tag

      def initialize(context, slot)
        @source = Core::Bytes.open(context.database.core, slot, bound: context.read_bound)
        @start = 0
        @size = @source.size
        @format_tag = @source.format_tag
      end

      def read(position, length)
        unless position >= 0 && length >= 0 && position + length <= size
          raise InvalidValueError, "truncated byte payload"
        end

        @source.read(@start + position, length)
      end

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

      def slice(position, length)
        read(position + length, 0)
        output = dup
        output.instance_variable_set(:@size, length)
        output.instance_variable_set(:@format_tag, nil)
        output.instance_variable_set(:@start, @start + position)
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
        Core::Bytes.append(context.writable_transaction, size: size, prefix: prefix, format_tag: format_tag,
                                                         representation: :external) do |position, length|
          read(position, length)
        end
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
