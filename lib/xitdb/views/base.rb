# frozen_string_literal: true

module XitDB
  # Collection handles that resolve values through an owning snapshot or transaction.
  #
  # Views load entries on demand. Their lifetime ends when the database closes;
  # transaction views also expire when their transaction ends.
  module Views
    # Distinguishes omitted arguments from stored nil values.
    # @api private
    class MissingArgument
      # Freeze the sentinel used to distinguish an omitted argument from nil.
      # @api private
      def initialize
        freeze
      end
    end

    # Tracks a collection location and its owning snapshot or transaction.
    #
    # Application code obtains views by reading collections from a root.
    # Use {#to_ruby} to produce independent ordinary Ruby containers.
    class Base
      include Enumerable

      # Largest signed native long accepted by Ruby-style index conversions.
      LONG_MAX = (1 << (([0].pack("l!").bytesize * 8) - 1)) - 1
      private_constant :LONG_MAX

      # @!attribute [r] context
      #   Owner used for lifetime checks and explicit cross-file copying.
      #   @return [Context]
      # @!attribute [r] path
      #   Immutable selectors from the context root to this collection.
      #   @return [::Array<Object>]
      # @!attribute [r] kind
      #   Logical map, array, or set variant.
      #   @return [Symbol]
      attr_reader :context, :path, :kind

      # Bind a view to a collection location; callers obtain views by reading values.
      # @api private
      # @param context [Context] snapshot or transaction owner
      # @param path [::Array<Object>] selectors from the logical root
      # @param kind [Symbol] logical collection kind
      # @param slot [Core::Slot, nil] resolved reference retained until the logical root changes
      def initialize(context:, path:, kind:, slot: nil)
        @context = context
        @path = path.map { |selector| selector.is_a?(String) ? selector.dup.freeze : selector }.freeze
        @kind = kind
        @stored_slot = slot
        @stored_root = context.root
        @location = context.observe(@path)
      end

      # Reject closed handles, ended transactions, and replaced ancestor locations.
      # @api private
      # @return [void]
      # @raise [ClosedError, ExpiredViewError] if this view is no longer usable
      def check!
        context.check!
        return unless @location&.expired

        raise ExpiredViewError, "view ancestor was replaced"
      end

      # Resolve the collection's stored reference at its current location.
      # @api private
      # @return [Core::Slot]
      def slot
        context.read do
          check!
          stored = @stored_slot
          return stored if stored && (!context.transaction || @stored_root.equal?(context.root))

          stored = context.resolve(path)
          unless frozen?
            @stored_root = context.root
            @stored_slot = stored
          end
          stored
        end
      end

      # Select the profile's collection operations for this stored value.
      # @api private
      # @return [Profiles::Portable::Adapter, Ruby::Containers]
      def adapter
        context.collection(slot, path: path)
      end

      # Count entries in the collection. Uncounted hash layouts may need traversal.
      # @return [Integer] nonnegative entry count
      def size
        context.read { adapter.size }
      end

      # Report whether the collection has no entries.
      # @return [Boolean]
      def empty?
        size.zero?
      end

      # Visit map key/value pairs, array values, or set members.
      #
      # Adding or deleting entries during iteration raises ConcurrentModificationError.
      # Transaction iteration reads replacement values from their live locations.
      # @yield [key_or_value, value] maps yield two arguments; other collections yield one
      # @yieldparam key_or_value [Object]
      # @yieldparam value [Object] map value only
      # @return [self, Enumerator]
      # @raise [ConcurrentModificationError] if membership changes during iteration
      def each
        return enum_for(:each) unless block_given?

        each_entries(-> { adapter.each_entry }) do |*entry|
          if %i[map sorted_map].include?(kind)
            yield entry[0], entry[1]
          else
            yield entry[0]
          end
        end
      end

      # Return a stored reference that a compatible destination can share.
      # @api private
      # @return [Core::Slot]
      def slot_for_assignment(**)
        slot
      end

      # Copy the complete collection into ordinary Ruby containers.
      #
      # The resulting Hash, Array, or Set no longer needs the database handle.
      # This reads every nested entry and needs memory for the complete result.
      # @return [::Hash, ::Array, ::Set] independent materialized value
      # @raise [CyclicValueError] if stored references form a cycle
      def to_ruby
        context.read { ValueWalker.materialize(self) }
      end

      # Compare fully materialized values using Ruby equality.
      # @param other [Object] Ruby value or another collection view
      # @return [Boolean]
      def ==(other)
        context.read do
          case other
          when Base then other = other.to_ruby
          end
          to_ruby == other
        end
      end

      # Describe the view's profile and bounded location without loading its contents.
      # @return [String]
      def inspect
        location = path.first(4).map { |selector| selector.is_a?(String) ? selector.byteslice(0, 32) : selector }
        suffix = path.size > 4 ? "..." : ""
        "#<#{self.class} profile=#{context.profile.class.name} path=#{location.inspect}#{suffix}>"
      end

      # Read an untagged byte value through a block-scoped stream.
      #
      # Reads can request small chunks without loading the complete value.
      # The reader expires after the block; overlapping writes are blocked while open.
      # @param key [Object] map key or array position
      # @yield [reader]
      # @yieldparam reader [Streams::Reader]
      # @return [Object] block result
      # @raise [KeyError] if the selected entry is absent
      # @raise [InvalidValueError] if the entry is not untagged bytes
      def open_bytes(key)
        raise ArgumentError, "open_bytes requires a block" unless block_given?

        # @type var reader: Streams::Reader?
        reader = nil
        registration = nil
        reader = context.read do
          selector = stream_selector(key)
          if %i[array linked_array].include?(kind) && !integer_argument!(selector).between?(0, size - 1)
            raise KeyError, "byte value not found"
          end

          registration = context.register_stream(entry_path(selector), write: false)
          stored = adapter.lookup(selector)
          raise KeyError, "byte value not found" unless stored

          Streams::Reader.new(context, stored)
        end
        yield reader
      ensure
        reader&.expire!
        context.release_stream(registration) if registration
      end

      # Replace a byte value after the writer block completes successfully.
      #
      # Data first goes to a temporary file. An exception leaves the entry unchanged.
      # The writer expires after the block. The enclosing transaction must still commit.
      # @param key [Object] map key or array position
      # @yield [writer]
      # @yieldparam writer [Streams::Writer]
      # @return [Object] block result
      # @raise [ReadOnlyError] unless the view belongs to an active writable transaction
      # @raise [ConcurrentModificationError] if another active stream overlaps
      def write_bytes(key)
        raise ArgumentError, "write_bytes requires a block" unless block_given?

        check!
        context.writable!
        selector = stream_selector(key)
        if %i[array linked_array].include?(kind)
          selector = integer_argument!(selector)
          raise IndexError, "array index outside list" if selector.negative?

          validate_growth!(selector + 1)
        end
        context.check_stream_mutation!(path, **stream_mutation(selector))
        Tempfile.create("xitdb-bytes", binmode: true) do |spool|
          writer = Streams::Writer.new(context, spool)
          registration = context.register_stream(entry_path(selector), write: true)
          begin
            result = yield writer
          ensure
            writer.expire!
            context.release_stream(registration)
          end
          present = !adapter.lookup(selector).nil?
          edit(**stream_mutation(selector)) do |collection|
            spool.rewind
            stored = Core::Bytes.copy(spool, size: spool.size, database: context.database.core,
                                             transaction: context.writable_transaction!)
            if %i[array linked_array].include?(kind)
              position = integer_argument!(selector)
              collection.assign(collection.size, Core::Slot.null) while collection.size < position
            end
            collection.assign(selector, stored)
          end
          context.replace_location(entry_path(selector))
          context.change_membership(path) unless present
          result
        end
      end

      protected

      # Clear storage only when the profile reports that a change is needed.
      # @return [Boolean] whether entries or profile metadata changed
      def clear_entries
        collection = adapter
        needed = if defined?(Ruby::Containers) && collection.is_a?(Ruby::Containers)
                   collection.clear_needed?
                 else
                   !collection.empty?
                 end
        return false unless needed

        edit do |current|
          if defined?(Ruby::Containers) && current.is_a?(Ruby::Containers)
            current.clear
          else
            current.each_entry { |selector, _| current.delete(selector) }
          end
        end
        true
      end

      # Apply adapter changes inside a context mutation checkpoint.
      # @param options [::Hash] stream conflict locations passed to Context#mutate
      # @yield [collection]
      # @yieldparam collection [Profiles::Portable::Adapter, Ruby::Containers]
      # @return [void]
      def edit(**options)
        context.mutate(path, **options) do |cursor|
          collection = context.collection(cursor.slot, path: path)
          yield collection
          cursor.replace(collection.slot)
        end
      end

      # Validate and copy a stream key so caller mutation cannot move its location.
      # @param key [Object]
      # @return [Object] normalized selector
      def stream_selector(key)
        check!
        case kind
        when :map, :sorted_map
          collection = adapter
          if defined?(Ruby::Containers) && collection.is_a?(Ruby::Containers)
            collection.selector_identity(key)
          else
            context.profile.key_bytes(key)
          end
          case key
          when String, Time then key.dup.freeze
          else key
          end
        when :array, :linked_array then normalize_index(key)
        else raise TypeError, "byte streams require a map or array view"
        end
      end

      # Describe which key or array positions a stream assignment can affect.
      # @param selector [Object]
      # @return [::Hash] conflict check options
      def stream_mutation(selector)
        if %i[array linked_array].include?(kind)
          position = integer_argument!(selector)
          { positions: [size, position].min..position }
        else
          { targets: [entry_path(selector)] }
        end
      end

      # Apply Ruby's implicit integer conversion and native long bounds.
      # @param value [Object]
      # @return [Integer]
      # @raise [TypeError, RangeError] if conversion or bounds validation fails
      def integer_argument!(value)
        result = ::Integer.try_convert(value) || raise(TypeError, "no implicit conversion into Integer")
        raise RangeError, "integer too big to convert into long" unless result.between?(-LONG_MAX - 1, LONG_MAX)

        result
      end

      # Retain the current structure before later transaction changes.
      # @param readonly [Boolean] forbid writes through the captured context
      # @return [Context] still subject to the owning transaction's lifetime
      def captured_context(readonly: false)
        stored = slot
        context.transaction&.freeze
        Context.new(database: context.database, root: stored, bound: context.read_bound,
                    transaction: context.transaction, readonly: readonly, reference_proof: context.reference_proof)
      end

      # Extend this collection's path with one child selector.
      # @param selector [Object]
      # @return [::Array<Object>]
      def entry_path(selector)
        path + [selector]
      end

      # Decode one entry per read operation and check the membership generation.
      # @param entries [#call] creates a storage iterator
      # @param selectors_only [Boolean] skip value decoding
      # @yield [*values] decoded arguments for one entry
      # @return [self]
      def each_entries(entries, selectors_only: false)
        # @type var iterator: Enumerator[entry, adapter]?
        iterator = nil
        generation = nil
        exhausted = false
        while true # rubocop:disable Style/InfiniteLoop -- Consumer StopIteration must propagate.
          values = context.read do
            check!
            unless iterator
              iterator = entries.call
              generation = @location&.membership
            end
            if @location&.membership != generation
              raise ConcurrentModificationError, "collection membership changed during iteration"
            end

            begin
              active_iterator = iterator || raise(ConcurrentModificationError, "missing collection iterator")
              selector, stored = active_iterator.next
            rescue StopIteration
              exhausted = true
              next
            end
            decode_entry(selector, stored, selectors_only: selectors_only == true)
          end
          break if exhausted

          yield(*values)
        end
        self
      end

      # Select iterator arguments and resolve live transaction replacements.
      # @param selector [Object]
      # @param stored [Core::Slot]
      # @param selectors_only [Boolean]
      # @return [::Array<Object>] arguments for the consumer block
      def decode_entry(selector, stored, selectors_only:)
        return [selector] if selectors_only || %i[set sorted_set].include?(kind)

        # Transaction entries resolve again so replacement values stay live.
        if context.transaction
          stored = adapter.lookup(selector) || raise(ExpiredViewError, "view location no longer exists")
        end
        value = context.profile.decode(stored, context: context, path: entry_path(selector))
        %i[map sorted_map].include?(kind) ? [selector, value] : [value]
      end
    end
  end
end
