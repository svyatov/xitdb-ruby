# frozen_string_literal: true

require "set"

module XitDB
  module ValueWalker
    # Frames retain only the current ancestors and their incremental iterators.
    def self.encode(value, context:, path:)
      profile = context.profile
      active = {}
      stack = []
      current = [value, path]
      while true
        if current
          input, location = current
          current = nil
          if input.is_a?(Views::Base)
            input.check!
            unless input.context.reference_compatible?(context)
              raise ForeignValueError.new("view belongs to another store or file generation", path: location)
            end
            context.transaction.freeze
            result = input.slot_for_assignment(context: context, path: location)
            if result.empty?
              current = [{}, location]
              next
            end
          elsif (kind = profile.input_kind(input, path: location))
            if active[input.object_id]
              raise CyclicValueError.new("cyclic value at #{location.inspect}", path: location)
            end
            active[input.object_id] = true
            adapter = profile.empty_container(kind, context: context, path: location)
            stack << [input, location, adapter, profile.input_entries(input, path: location), nil]
            result = nil
          else
            begin
              result = profile.encode_scalar(input, core: context.database.core)
            rescue ValueError => error
              raise error.class.new("#{error.message} at #{location.inspect}", path: location), cause: error
            end
          end
        end
        if result
          return result if stack.empty?

          frame = stack.last
          frame[2].assign(frame[4], result)
        end
        frame = stack.last
        begin
          selector, child = frame[3].next
          frame[4] = selector
          current = [child, frame[1] + [selector]]
        rescue StopIteration
          result = frame[2].slot
          active.delete(frame[0].object_id)
          stack.pop
          return result if stack.empty?

          stack.last[2].assign(stack.last[4], result)
          result = nil
        end
      end
    end

    def self.materialize(view)
      view.check!
      context = view.context
      profile = context.profile
      active = {}
      stack = []
      current = [view.slot, view.path]
      selected = view.adapter
      result = nil
      while true
        if current
          slot, path = current
          current = nil
          adapter = selected || profile.container(slot, context: context, path: path)
          selected = nil
          if adapter
            identity = [slot.tag, slot.value]
            raise CyclicValueError.new("cyclic stored value", path: path) if active[identity]

            active[identity] = true
            output = case adapter.kind
            when :map, :sorted_map then {}
            when :set, :sorted_set then Set.new
            else []
            end
            stack << [identity, path, adapter.each_entry, output, nil]
          else
            result = profile.decode(slot, context: context, path: path, immutable: false)
            insert(stack.last, result)
          end
        end
        frame = stack.last
        begin
          selector, child = frame[2].next
          frame[4] = selector.is_a?(String) ? selector.dup : selector
          if frame[3].is_a?(Set)
            frame[3].add(frame[4])
          else
            current = [child, frame[1] + [selector]]
          end
        rescue StopIteration
          active.delete(frame[0])
          stack.pop
          result = frame[3]
          return result if stack.empty?

          insert(stack.last, result)
        end
      end
    end

    def self.insert(frame, value)
      output = frame[3]
      output.is_a?(Hash) ? output[frame[4]] = value : output << value
    end
    private_class_method :insert
  end
end
