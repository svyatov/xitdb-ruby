# frozen_string_literal: true

require_relative "input_guard"

module XitDB
  # Encodes and materializes nested values without recursive tree traversal.
  #
  # Each traversal records active ancestors to detect cycles. Sibling values
  # may share an object; only a reference to an active ancestor is a cycle.
  # @api private
  module ValueWalker
    # Frames retain only the current ancestors and their incremental iterators.
    # Encode a nested Ruby value using one traversal frame per active ancestor.
    #
    # A frame stores a container, its path, an iterator, and the pending selector.
    # This keeps deep input from consuming Ruby's method call stack.
    # @param value [Object] supported input
    # @param context [Context] writable destination
    # @param path [Array<Object>] destination location
    # @return [Core::Slot]
    # @raise [CyclicValueError] if an input contains itself through its descendants
    def self.encode(value, context:, path:)
      state = context.profile.packing_state(context: context, reading: false)
      # @type var active: ::Hash[Integer, bool]
      active = {}
      # @type var stack: ::Array[encoding_frame]
      stack = []
      # @type var current: [top, path]?
      current = [value, path]
      # @type var result: Core::Slot?
      result = nil
      while true # rubocop:disable Style/InfiniteLoop -- Codec StopIteration must propagate.
        if current
          result = begin_encoding(current[0], current[1], context, active, stack, state)
          current = nil
        end
        if result
          break if stack.empty?

          assign_encoding_parent(stack, result)
        end
        frame = stack.last || raise(CorruptionError, "missing encoding frame")
        entry = next_input(frame)
        if entry
          selector, child = entry
          frame[4] = selector
          current = [child, frame[1] + [selector]]
        else
          result = finish_encoding(frame, active, stack)
          break if stack.empty?

          result = nil
        end
      end
      result || raise(CorruptionError, "encoding produced no value")
    end

    # Build independent Ruby containers from a database view without recursive traversal.
    # @param view [Views::Base]
    # @return [Hash, Array, Set]
    # @raise [CyclicValueError] if stored references form an ancestor cycle
    def self.materialize(view)
      view.check!
      context = view.context
      state = context.profile.packing_state(context: context, reading: true)
      # @type var active: ::Hash[[Symbol, Integer], bool]
      active = {}
      # @type var stack: ::Array[materialization_frame]
      stack = []
      # @type var current: [Core::Slot, path]?
      current = [view.slot, view.path]
      # @type var selected: adapter | Views::Slice::Selection | nil
      selected = view.adapter
      # @type var materialized: materialized?
      materialized = nil
      while true # rubocop:disable Style/InfiniteLoop -- Codec StopIteration must propagate.
        if current
          begin_materialization(current[0], current[1], selected, context, active, stack, state)
          current = nil
          selected = nil
        end
        frame = stack.last || raise(CorruptionError, "missing materialization frame")
        entry = next_stored_entry(frame)
        if entry
          current = materialized_child(frame, entry)
        else
          materialized = finish_materialization(frame, active, stack)
          break if stack.empty?
        end
      end
      materialized || raise(CorruptionError, "materialization produced no value")
    end

    # Validate input and encode a scalar or push a container traversal frame.
    # @return [Core::Slot, nil]
    def self.begin_encoding(input, location, context, active, stack, state)
      InputGuard.check!(input, path: location)
      case input
      when Views::Base then encode_view(input, context, location)
      else
        profile = context.profile
        kind = profile.input_kind(input, path: location)
        return encode_scalar(input, context, location, state) unless kind

        identity = BasicObject.instance_method(:__id__).bind_call(input)
        raise CyclicValueError.new("cyclic value at #{location.inspect}", path: location) if active[identity]

        active[identity] = true
        adapter = profile.empty_container(kind, context: context, path: location, state: state)
        stack << [input, location, adapter, profile.input_entries(input, path: location, state: state), nil]
        nil
      end
    end

    # Reuse a compatible stored reference after freezing transaction structure.
    # @return [Core::Slot]
    # @raise [ForeignValueError] if reference sharing is unsafe
    def self.encode_view(input, context, location)
      input.check!
      unless input.context.reference_compatible?(context)
        raise ForeignValueError.new("view belongs to another store or file generation", path: location)
      end

      context.writable_transaction!.freeze
      assigned = input.slot_for_assignment(context: context, path: location)
      assigned.empty? ? encode({}, context: context, path: location) : assigned
    end

    # Encode a scalar and attach its logical path to value errors.
    # @return [Core::Slot]
    def self.encode_scalar(input, context, location, state)
      context.profile.encode_scalar(input, core: context.database.core, state: state)
    rescue ValueError => e
      raise e.class.new("#{e.message} at #{location.inspect}", path: location), cause: e
    end

    # Attach an encoded child at the parent frame's pending selector.
    # @return [void]
    def self.assign_encoding_parent(stack, stored)
      frame = stack.last || raise(CorruptionError, "missing encoding frame")
      frame[2].assign(frame[4], stored)
    end

    # Pop a completed container and attach its stored reference to its parent.
    # @return [Core::Slot]
    def self.finish_encoding(frame, active, stack)
      stored = frame[2].slot
      active.delete(BasicObject.instance_method(:__id__).bind_call(frame[0]))
      stack.pop
      assign_encoding_parent(stack, stored) unless stack.empty?
      stored
    end

    # Read the next input pair, rescuing only iterator exhaustion.
    # @return [Array, nil]
    def self.next_input(frame)
      frame[3].next
    rescue StopIteration
      nil
    end

    # Decode a scalar into its parent or push a fresh Ruby container frame.
    # @return [void]
    def self.begin_materialization(slot, path, selected, context, active, stack, state)
      adapter = selected || context.profile.container(slot, context: context, path: path, state: state)
      unless adapter
        result = context.profile.decode(slot, context: context, path: path, immutable: false)
        frame = stack.last || raise(CorruptionError, "missing materialization frame")
        insert(frame, result)
        return
      end

      # @type var identity: [Symbol, Integer]
      identity = [slot.tag, slot.value]
      raise CyclicValueError.new("cyclic stored value", path: path) if active[identity]

      active[identity] = true
      # @type var output: materialized
      output = case adapter.kind
               when :map, :sorted_map then {}
               when :set, :sorted_set then Set.new
               else []
               end
      stack << [identity, path, adapter.each_entry, output, nil]
    end

    # Read the next stored selector/slot pair, or nil when exhausted.
    # @return [Array, nil]
    def self.next_stored_entry(frame)
      frame[2].next
    rescue StopIteration
      nil
    end

    # Insert a set member directly or select the next value for decoding.
    # @return [Array(Core::Slot, Array), nil]
    def self.materialized_child(frame, entry)
      selector, child = entry
      frame[4] = selector.is_a?(String) ? selector.dup : selector
      if frame[3].is_a?(Set)
        frame[3].add(frame[4])
        nil
      else
        [child, frame[1] + [selector]]
      end
    end

    # Pop a completed Ruby container and insert it into its parent.
    # @return [Hash, Array, Set]
    def self.finish_materialization(frame, active, stack)
      active.delete(frame[0])
      stack.pop
      output = frame[3]
      unless stack.empty?
        parent = stack.last || raise(CorruptionError, "missing materialization parent")
        insert(parent, output)
      end
      output
    end

    # Put a decoded value into the pending Hash key or Array position.
    # @return [void]
    def self.insert(frame, value)
      output = frame[3]
      case output
      when Hash then output[frame[4]] = value
      when Array then output << value
      end
    end
    private_class_method :insert, :begin_encoding, :encode_view, :encode_scalar, :assign_encoding_parent,
                         :finish_encoding, :next_input, :begin_materialization, :next_stored_entry,
                         :materialized_child, :finish_materialization
  end
end
