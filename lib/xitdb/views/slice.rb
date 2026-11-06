# frozen_string_literal: true

module XitDB
  module Views
    # A captured, read-only range of an array.
    #
    # Later writes leave the selection's captured structure unchanged.
    # The selection still expires with its transaction or database handle.
    class Slice < Array
      # Bind a selection to a captured array structure.
      # @api private
      # @param offset [Integer] first backing position
      # @param count [Integer] visible entries
      def initialize(offset:, count:, **)
        super(**)
        @offset = offset
        @count = count
      end

      # Wrap the underlying adapter with this slice's visible bounds.
      # @api private
      # @return [Selection]
      def adapter
        Selection.new(super, @offset, @count)
      end

      # Create storage for just the selected range in a compatible destination.
      # @api private
      # @param context [Context]
      # @param path [::Array<Object>] destination location
      # @return [Core::Slot]
      def slot_for_assignment(context:, path:)
        context.collection(slot, path: path).slice(@offset, @count)
      end

      protected

      # Return the start position within the original backing array.
      # @return [Integer]
      def slice_offset
        @offset
      end

      # Translate a slice-relative selector to its backing array position.
      # @param selector [Integer]
      # @return [::Array<Object>]
      def entry_path(selector)
        path + [@offset + selector]
      end

      # Limits the adapter's visible entries to the captured range.
      # @api private
      class Selection
        # @return [Integer] number of entries visible in this selection
        attr_reader :size

        # Restrict a storage adapter to a fixed range without decoding entries.
        # @param source [Profiles::Portable::Adapter, Ruby::Containers]
        # @param offset [Integer]
        # @param count [Integer]
        def initialize(source, offset, count)
          @source = source
          @offset = offset
          @size = count
        end

        # Preserve the backing array's logical collection kind.
        # @return [Symbol]
        def kind
          @source.kind
        end

        # Translate a selection-relative position into the backing adapter.
        # @param index [Integer]
        # @return [Core::Slot, nil]
        def lookup(index)
          @source.lookup(@offset + index)
        end

        # Visit selected slots with positions starting at zero.
        # @yield [index, slot]
        # @yieldparam index [Integer]
        # @yieldparam slot [Core::Slot]
        # @return [self, Enumerator]
        def each_entry
          return enum_for(:each_entry) unless block_given?
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
