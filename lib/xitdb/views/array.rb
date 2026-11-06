# frozen_string_literal: true

module XitDB
  module Views
    # Provides indexed reads and writes for persistent arrays.
    #
    # Positions start at zero. Negative positions count from the end.
    # Reading a range captures a {Slice}; it does not create a writable subarray.
    class Array < Base
      # Sentinel for an omitted count or default, distinct from an explicit nil.
      UNSET = MissingArgument.new.freeze
      private_constant :UNSET

      alias length size

      # Read an element or capture a read-only range without loading the whole array.
      # @param index [Integer, Range] negative positions count from the end
      # @param count [Integer] optional slice length
      # @return [Object, Slice, nil] element, captured range, or nil outside the array
      # @see Slice
      def [](index, count = UNSET)
        context.read { read_index(index, count) }
      end

      # Choose element, range, or start/count selection.
      # @param index [Integer, Range]
      # @param count [Integer, MissingArgument]
      # @return [Object, Slice, nil]
      def read_index(index, count)
        return read_slice(integer_argument!(index), integer_argument!(count)) unless count.equal?(UNSET)
        return read_range(index) if index.is_a?(Range)

        index = normalize_index(index)
        return nil unless index >= 0 && index < size

        stored = adapter.lookup(index) || raise(IndexError, "array index outside list")
        context.profile.decode(stored, context: context, path: entry_path(index))
      end
      private :read_index

      # Translate inclusive, exclusive, and open-ended ranges into a bounded slice.
      # @param index [Range]
      # @return [Slice, nil]
      def read_range(index)
        start = index.begin.nil? ? 0 : integer_argument!(index.begin)
        finish = index.end.nil? ? size : integer_argument!(index.end)
        start += size if start.negative?
        return nil if start.negative? || start > size

        finish += size if finish.negative?
        finish += 1 unless index.exclude_end? || index.end.nil?
        read_slice(start, [finish - start, 0].max)
      end
      private :read_range

      # Read an element with a default or fallback block for an absent position.
      # @param index [Integer] negative positions count from the end
      # @param default [Object] fallback; omitted means raise
      # @yield [index] compute a fallback, taking precedence over the default
      # @yieldparam index [Integer]
      # @return [Object]
      # @raise [IndexError] if absent without a default or block
      def fetch(index, default = UNSET)
        found, value = context.read do
          position = normalize_index(index)
          present = position >= 0 && position < size
          [present, present ? self[position] : nil]
        end
        return value if found
        return yield index if block_given?

        case default
        when MissingArgument then nil
        else return default
        end

        raise IndexError, "array index outside list"
      end

      # Read the first element or collect up to count values into a Ruby Array.
      # @param count [Integer] optional nonnegative number of values
      # @return [Object, ::Array, nil] one value, an array, or nil for an empty array
      def first(count = UNSET)
        context.read do
          check!
          return self[0] if count.equal?(UNSET)

          requested = nonnegative_count!(count)
          each.take(requested)
        end
      end

      # Read the last element or collect up to count values in their original order.
      # @param count [Integer] optional nonnegative number of values
      # @return [Object, ::Array, nil]
      def last(count = UNSET)
        context.read do
          return self[-1] if count.equal?(UNSET)

          requested = [nonnegative_count!(count), size].min
          ((size - requested)...size).map { |index| self[index] }
        end
      end

      # Assign one position, filling any gap with nil values.
      # @param index [Integer] negative positions refer to existing positions from the end
      # @param value [Object] value supported by the profile
      # @return [Object] assigned value
      # @raise [IndexError] if the position remains negative or exceeds storage limits
      # @raise [ReadOnlyError] unless the view is writable
      def []=(index, value)
        check!
        context.writable!
        index = normalize_index(index)
        raise IndexError, "array index outside list" if index.negative?

        validate_growth!(index + 1)

        previous_size = size
        edit(positions: [previous_size, index].min..index) do |collection|
          stored = context.profile.encode(value, context: context, path: path + [index])
          collection.assign(collection.size, Core::Slot.null) while collection.size < index
          collection.assign(index, stored)
        end
        context.replace_location(path + [index])
        context.change_membership(path) if index >= previous_size
        value
      end

      # Append one value and return this view.
      # @param value [Object]
      # @return [self]
      def <<(value)
        push(value)
      end

      # Append values together as one logical mutation.
      # @param values [::Array<Object>]
      # @return [self]
      def push(*values)
        insert(size, *values)
      end

      # Radix arrays shift the suffix for insertion and deletion. Linked arrays
      # use their positional tree operations; neither operation decodes values.
      # Insert values before a position and expire views at shifted positions.
      #
      # An index of -1 appends. Positions beyond the end create nil-filled gaps.
      # @param index [Integer]
      # @param values [::Array<Object>]
      # @return [self]
      # @raise [IndexError] if the normalized position is negative
      def insert(index, *values)
        check!
        context.writable!
        index = integer_argument!(index)
        return self if values.empty?

        previous_size = size
        index += previous_size + 1 if index.negative?
        raise IndexError, "array index outside list" if index.negative?

        validate_growth!([previous_size, index].max + values.size)
        edit(positions: [previous_size, index].min..) do |collection|
          encoded = values.each_with_index.map do |value, offset|
            context.profile.encode(value, context: context, path: path + [index + offset])
          end
          collection.assign(collection.size, Core::Slot.null) while collection.size < index
          encoded.each_with_index { |stored, offset| collection.insert(index + offset, stored) }
        end
        invalidate_positions(index)
        self
      end

      # Remove one position and shift later entries left.
      # @param index [Integer] negative positions count from the end
      # @return [Object, nil] removed value or nil outside the array
      def delete_at(index)
        check!
        context.writable!
        index = normalize_index(index)
        previous_size = size
        return nil unless index >= 0 && index < previous_size

        context.check_stream_mutation!(path, positions: index..)

        value = nil
        edit(positions: index..) do |collection|
          captured = captured_context
          stored = collection.lookup(index) || raise(IndexError, "array index outside list")
          value = context.profile.decode(stored, context: captured, path: [index])
          collection.delete(index)
        end
        invalidate_positions(index)
        value
      end

      # Remove the last value or up to count values from the end.
      # @param count [Integer] optional nonnegative number to remove
      # @return [Object, ::Array, nil] removed value, ordered array of values, or nil
      def pop(count = UNSET)
        check!
        context.writable!
        return delete_at(-1) if count.equal?(UNSET)

        count = [nonnegative_count!(count), size].min
        return [] if count.zero?

        previous_size = size
        context.check_stream_mutation!(path, positions: (previous_size - count)..)
        values = nil
        edit(positions: (previous_size - count)..) do |collection|
          captured = captured_context
          values = ((previous_size - count)...previous_size).map do |index|
            stored = collection.lookup(index) || raise(IndexError, "array index outside list")
            context.profile.decode(stored, context: captured, path: [index])
          end
          collection.truncate(previous_size - count)
        end
        invalidate_positions(previous_size - count)
        values
      end

      # Append the contents of arrays or compatible array views in one mutation.
      # @param others [::Array<::Array, Views::Array>] input collections
      # @return [self]
      # @raise [TypeError] if an input cannot be converted to an array
      def concat(*others)
        check!
        context.writable!
        added = false
        edit(positions: size..) do |collection|
          inputs = others.map do |other|
            case other
            when Array then nil
            else other = ::Array.try_convert(other) || raise(TypeError, "concat requires an array")
            end
            stored = context.profile.encode(other, context: context, path: path)
            context.collection(stored, path: path)
          end
          inputs.each do |input|
            next if input.empty?

            validate_growth!(collection.size + input.size)
            added = true
            collection.concat(input)
          end
        end
        context.change_membership(path) if added
        self
      end

      # Remove all values and expire child views.
      # @return [self]
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

      # Reject a size that cannot fit the supported native array index range.
      # @param count [Integer]
      # @return [void]
      def validate_growth!(count)
        raise IndexError, "array size too big" if count > LONG_MAX / 0.size
      end

      # Convert an index and translate negative positions relative to size.
      # @param index [Object]
      # @return [Integer]
      def normalize_index(index)
        index = integer_argument!(index)
        index.negative? ? index + size : index
      end

      # Convert a requested length and reject negative counts.
      # @param count [Object]
      # @return [Integer]
      def nonnegative_count!(count)
        count = integer_argument!(count)
        raise ArgumentError, "negative array size" if count.negative?

        count
      end

      # Capture a bounded selection with a read-only context.
      # @param start [Integer]
      # @param count [Integer]
      # @return [Slice, nil]
      def read_slice(start, count)
        start += size if start.negative?
        return nil if start.negative? || start > size || count.negative?

        count = [count, size - start].min
        Slice.new(context: captured_context(readonly: true), path: [], kind: kind,
                  offset: slice_offset + start, count: count)
      end

      # Return the start position within the original backing array.
      # @return [Integer]
      def slice_offset
        0
      end

      # Expire moved child locations and invalidate active membership iterators.
      # @param start [Integer] first affected position
      # @return [void]
      def invalidate_positions(start)
        context.invalidate_positions(path, start)
        context.change_membership(path)
      end
    end
  end
end

require_relative "slice"
