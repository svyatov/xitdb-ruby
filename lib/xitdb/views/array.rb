# frozen_string_literal: true

module XitDB
  module Views
    class Array < Base
      UNSET = Object.new.freeze
      private_constant :UNSET

      alias length size

      def [](index, count = UNSET)
        unless count.equal?(UNSET)
          return read_slice(integer_argument(index), integer_argument(count))
        end
        if index.is_a?(Range)
          start = index.begin.nil? ? 0 : integer_argument(index.begin)
          finish = index.end.nil? ? size : integer_argument(index.end)
          start += size if start.negative?
          return nil if start.negative? || start > size

          finish += size if finish.negative?
          finish += 1 unless index.exclude_end? || index.end.nil?
          return read_slice(start, [finish - start, 0].max)
        end
        index = normalize_index(index)
        return nil unless index >= 0 && index < size

        context.profile.decode(adapter.lookup(index), context: context, path: entry_path(index))
      end

      def fetch(index, default = UNSET)
        position = normalize_index(index)
        return self[position] if position >= 0 && position < size
        return yield index if block_given?
        return default unless default.equal?(UNSET)

        raise IndexError, "array index outside list"
      end

      def first(count = UNSET)
        check!
        return self[0] if count.equal?(UNSET)

        count = nonnegative_count(count)
        each.take(count)
      end

      def last(count = UNSET)
        return self[-1] if count.equal?(UNSET)

        count = [nonnegative_count(count), size].min
        ((size - count)...size).map { |index| self[index] }
      end

      def []=(index, value)
        check!
        context.writable!
        index = normalize_index(index)
        raise IndexError, "array index outside list" if index.negative?
        validate_growth(index + 1)

        previous_size = size
        edit do |collection|
          stored = context.profile.encode(value, context: context, path: path + [index])
          collection.assign(collection.size, Core::Slot.null) while collection.size < index
          collection.assign(index, stored)
        end
        context.replace_location(path + [index])
        context.change_membership(path) if index >= previous_size
        value
      end

      def <<(value)
        push(value)
      end

      def push(*values)
        insert(size, *values)
      end

      # Radix arrays shift the suffix for insertion and deletion. Linked arrays
      # use their positional tree operations; neither operation decodes values.
      def insert(index, *values)
        check!
        context.writable!
        index = integer_argument(index)
        return self if values.empty?

        previous_size = size
        index += previous_size + 1 if index.negative?
        raise IndexError, "array index outside list" if index.negative?

        validate_growth([previous_size, index].max + values.size)
        edit do |collection|
          encoded = values.each_with_index.map do |value, offset|
            context.profile.encode(value, context: context, path: path + [index + offset])
          end
          collection.assign(collection.size, Core::Slot.null) while collection.size < index
          encoded.each_with_index { |stored, offset| collection.insert(index + offset, stored) }
        end
        invalidate_positions(index)
        self
      end

      def delete_at(index)
        check!
        context.writable!
        index = normalize_index(index)
        previous_size = size
        return nil unless index >= 0 && index < previous_size

        captured = captured_context
        stored = adapter.lookup(index)
        value = context.profile.decode(stored, context: captured, path: [index])
        edit { |collection| collection.delete(index) }
        invalidate_positions(index)
        value
      end

      def pop(count = UNSET)
        check!
        context.writable!
        return delete_at(-1) if count.equal?(UNSET)

        count = [nonnegative_count(count), size].min
        return [] if count.zero?

        previous_size = size
        captured = captured_context
        values = ((previous_size - count)...previous_size).map do |index|
          context.profile.decode(adapter.lookup(index), context: captured, path: [index])
        end
        edit { |collection| collection.truncate(previous_size - count) }
        invalidate_positions(previous_size - count)
        values
      end

      def concat(*others)
        check!
        context.writable!
        added = false
        edit do |collection|
          inputs = others.map do |other|
            if other.is_a?(Array)
              unless other.context.database.equal?(context.database)
                raise ForeignValueError.new("view belongs to another database", path: path)
              end
            else
              other = ::Array.try_convert(other) || raise(TypeError, "concat requires an array")
            end
            stored = context.profile.encode(other, context: context, path: path)
            context.profile.container(stored, context: context, path: path)
          end
          inputs.each do |input|
            next if input.size.zero?

            validate_growth(collection.size + input.size)
            added = true
            collection.concat(input)
          end
        end
        context.change_membership(path) if added
        self
      end

      def clear
        check!
        context.writable!
        return self if empty?

        edit { |collection| collection.truncate(0) }
        context.invalidate_children(path)
        context.change_membership(path)
        self
      end

      protected

      def validate_growth(count)
        raise IndexError, "array size too big" if count > LONG_MAX / 0.size
      end

      def normalize_index(index)
        index = integer_argument(index)
        index.negative? ? index + size : index
      end

      def nonnegative_count(count)
        count = integer_argument(count)
        raise ArgumentError, "negative array size" if count.negative?

        count
      end

      def read_slice(start, count)
        start += size if start.negative?
        return nil if start.negative? || start > size || count.negative?

        count = [count, size - start].min
        Slice.new(context: captured_context(readonly: true), path: [], kind: kind,
                  offset: slice_offset + start, count: count)
      end

      def slice_offset
        0
      end

      def invalidate_positions(start)
        context.invalidate_positions(path, start)
        context.change_membership(path)
      end
    end

    class Slice < Array
      def initialize(offset:, count:, **options)
        super(**options)
        @offset = offset
        @count = count
      end

      def adapter
        Selection.new(super, @offset, @count)
      end

      def slot_for_assignment(context:, path:)
        context.profile.container(slot, context: context, path: path).slice(@offset, @count)
      end

      protected

      def slice_offset
        @offset
      end

      def entry_path(selector)
        path + [@offset + selector]
      end

      class Selection
        attr_reader :size

        def initialize(source, offset, count)
          @source = source
          @offset = offset
          @size = count
        end

        def kind
          @source.kind
        end

        def lookup(index)
          @source.lookup(@offset + index)
        end

        def each_entry
          return enum_for(__method__) unless block_given?
          return self if size.zero?

          index = 0
          @source.each_from_index(@offset) do |_selector, stored|
            yield index, stored
            index += 1
            break if index == size
          end
          self
        end
      end
      private_constant :Selection
    end
  end
end
