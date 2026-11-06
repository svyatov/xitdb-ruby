# frozen_string_literal: true

module XitDB
  # Copies logical entries with one iterator per ancestor and no node cache.
  #
  # Profiles interpret source values and construct destination values. An
  # explicit stack avoids Ruby call-stack limits on deeply nested input.
  # @api private
  class Conversion
    # Bind logical value readers and writers, with an optional application transform.
    # @param source [Context]
    # @param destination [Context] writable destination
    # @param transform [#call, nil] receives value:, path:, and role:
    def initialize(source, destination, transform: nil)
      @source = source
      @destination = destination
      @transform = transform
    end

    # Copy one value with an explicit stack of ancestors rather than recursive calls.
    #
    # Only the active traversal path retains iterators. Repeated references can be
    # copied more than once; a reference to an active ancestor is rejected.
    # @param slot [Core::Slot] source value
    # @param path [Array<Object>] source location for diagnostics and transforms
    # @param adapter [Object, nil] optional selected container adapter
    # @return [Core::Slot] encoded destination value
    # @raise [CyclicValueError] if stored values form an ancestor cycle
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

    # Copy a scalar immediately, or push a container frame after checking for a cycle.
    # @return [Core::Slot, nil] nil when the container needs further traversal
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

    # Stream compatible bytes directly or decode, transform, and encode a scalar.
    # @return [Core::Slot]
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

    # Assign a completed child to the current destination adapter.
    # @return [void]
    def assign_parent(stack, stored)
      parent = stack.last || raise(CorruptionError, "missing conversion parent")
      parent[3].assign(parent[4], stored)
    end

    # Finish a container, remove its active identity, and attach it to its parent.
    # @return [Core::Slot]
    def finish_frame(frame, stack, active)
      stored = frame[3].slot
      active.delete(frame[0])
      stack.pop
      assign_parent(stack, stored) unless stack.empty?
      stored
    end

    # Callback StopIteration must abort the operation, so rescue only #next.
    # Read the next source entry, rescuing exhaustion only from the iterator.
    # @return [Array, nil] nil at the end
    def next_entry(frame)
      frame[2].next
    rescue StopIteration
      nil
    end

    # Transform a key, detect collisions, and choose the next child to copy.
    # @return [Array(Core::Slot, Array), nil] nil for set members
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

    # Apply the key callback and reject unsupported destination key classes.
    # @return [Object] transformed selector
    def transform_key(value, path)
      converted = transform(value, path, :key)
      case converted
      when String, Integer, Float, Time, Symbol, TrueClass, FalseClass, NilClass, UInt
        converted
      else
        raise UnsupportedValueError.new("unsupported converted key", path: path)
      end
    end

    # Call application code with an owned immutable path and explicit key/value role.
    # @return [Object] unchanged input when no callback exists
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
  end
end

require_relative "conversion/byte_source"
