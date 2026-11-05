# frozen_string_literal: true

require_relative "input_guard"

module XitDB
  # Encodes and materializes nested values without recursive tree traversal.
  module ValueWalker
    # Frames retain only the current ancestors and their incremental iterators.
    def self.encode(value, context:, path:)
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
          result = begin_encoding(current[0], current[1], context, active, stack)
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

    def self.materialize(view)
      view.check!
      context = view.context
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
          begin_materialization(current[0], current[1], selected, context, active, stack)
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

    def self.begin_encoding(input, location, context, active, stack)
      InputGuard.check!(input, path: location)
      case input
      when Views::Base then encode_view(input, context, location)
      else
        profile = context.profile
        kind = profile.input_kind(input, path: location)
        return encode_scalar(input, context, location) unless kind

        identity = BasicObject.instance_method(:__id__).bind_call(input)
        raise CyclicValueError.new("cyclic value at #{location.inspect}", path: location) if active[identity]

        active[identity] = true
        adapter = profile.empty_container(kind, context: context, path: location)
        stack << [input, location, adapter, profile.input_entries(input, path: location), nil]
        nil
      end
    end

    def self.encode_view(input, context, location)
      input.check!
      unless input.context.reference_compatible?(context)
        raise ForeignValueError.new("view belongs to another store or file generation", path: location)
      end

      context.writable_transaction.freeze
      assigned = input.slot_for_assignment(context: context, path: location)
      assigned.empty? ? encode({}, context: context, path: location) : assigned
    end

    def self.encode_scalar(input, context, location)
      context.profile.encode_scalar(input, core: context.database.core)
    rescue ValueError => e
      raise e.class.new("#{e.message} at #{location.inspect}", path: location), cause: e
    end

    def self.assign_encoding_parent(stack, stored)
      frame = stack.last || raise(CorruptionError, "missing encoding frame")
      frame[2].assign(frame[4], stored)
    end

    def self.finish_encoding(frame, active, stack)
      stored = frame[2].slot
      active.delete(BasicObject.instance_method(:__id__).bind_call(frame[0]))
      stack.pop
      assign_encoding_parent(stack, stored) unless stack.empty?
      stored
    end

    def self.next_input(frame)
      frame[3].next
    rescue StopIteration
      nil
    end

    def self.begin_materialization(slot, path, selected, context, active, stack)
      adapter = selected || context.profile.container(slot, context: context, path: path)
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

    def self.next_stored_entry(frame)
      frame[2].next
    rescue StopIteration
      nil
    end

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
