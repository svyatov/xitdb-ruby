# frozen_string_literal: true

module XitDB
  module Views
    # Distinguishes omitted arguments from stored nil values.
    class MissingArgument
      def initialize
        freeze
      end
    end

    # Tracks a collection location and its owning snapshot or transaction.
    class Base
      include Enumerable

      LONG_MAX = (1 << (([0].pack("l!").bytesize * 8) - 1)) - 1
      private_constant :LONG_MAX

      attr_reader :context, :path, :kind

      def initialize(context:, path:, kind:)
        @context = context
        @path = path.map { |selector| selector.is_a?(String) ? selector.dup.freeze : selector }.freeze
        @kind = kind
        @location = context.observe(@path)
      end

      def check!
        context.check!
        return unless @location&.expired

        raise ExpiredViewError, "view ancestor was replaced"
      end

      def slot
        context.read do
          check!
          context.resolve(path)
        end
      end

      def adapter
        context.collection(slot, path: path)
      end

      def size
        context.read { adapter.size }
      end

      def empty?
        size.zero?
      end

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

      def slot_for_assignment(**)
        slot
      end

      def to_ruby
        context.read { ValueWalker.materialize(self) }
      end

      def ==(other)
        context.read do
          case other
          when Base then other = other.to_ruby
          end
          to_ruby == other
        end
      end

      def inspect
        location = path.first(4).map { |selector| selector.is_a?(String) ? selector.byteslice(0, 32) : selector }
        suffix = path.size > 4 ? "..." : ""
        "#<#{self.class} profile=#{context.profile.class.name} path=#{location.inspect}#{suffix}>"
      end

      def open_bytes(key)
        raise ArgumentError, "open_bytes requires a block" unless block_given?

        # @type var reader: Streams::Reader?
        reader = nil
        registration = nil
        reader = context.read do
          selector = stream_selector(key)
          if %i[array linked_array].include?(kind) && !integer_argument(selector).between?(0, size - 1)
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

      def write_bytes(key)
        raise ArgumentError, "write_bytes requires a block" unless block_given?

        check!
        context.writable!
        selector = stream_selector(key)
        if %i[array linked_array].include?(kind)
          selector = integer_argument(selector)
          raise IndexError, "array index outside list" if selector.negative?

          validate_growth(selector + 1)
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
                                             transaction: context.writable_transaction)
            if %i[array linked_array].include?(kind)
              position = integer_argument(selector)
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

      def clear_entries?
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

      def edit(**options)
        context.mutate(path, **options) do |cursor|
          collection = context.collection(cursor.slot, path: path)
          yield collection
          cursor.replace(collection.slot)
        end
      end

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

      def stream_mutation(selector)
        if %i[array linked_array].include?(kind)
          position = integer_argument(selector)
          { positions: [size, position].min..position }
        else
          { targets: [entry_path(selector)] }
        end
      end

      def integer_argument(value)
        result = ::Integer.try_convert(value) || raise(TypeError, "no implicit conversion into Integer")
        raise RangeError, "integer too big to convert into long" unless result.between?(-LONG_MAX - 1, LONG_MAX)

        result
      end

      def captured_context(readonly: false)
        stored = slot
        context.transaction&.freeze
        Context.new(database: context.database, root: stored, bound: context.read_bound,
                    transaction: context.transaction, readonly: readonly, reference_proof: context.reference_proof)
      end

      def entry_path(selector)
        path + [selector]
      end

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
