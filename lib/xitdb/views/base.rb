# frozen_string_literal: true

module XitDB
  module Views
    class Base
      include Enumerable

      LONG_MAX = (1 << ([0].pack("l!").bytesize * 8 - 1)) - 1
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
        if @location&.expired
          raise ExpiredViewError, "view ancestor was replaced"
        end
      end

      def slot
        context.read do
          check!
          context.resolve(path)
        end
      end

      def adapter
        context.profile.container(slot, context: context, path: path)
      end

      def size
        context.read { adapter.size }
      end

      def empty?
        size.zero?
      end

      def each
        return enum_for(__method__) unless block_given?

        each_entries(-> { adapter.each_entry }) { |*entry| yield(*entry) }
      end

      def slot_for_assignment(context:, path:)
        slot
      end

      def to_ruby
        context.read { ValueWalker.materialize(self) }
      end

      def ==(other)
        context.read do
          other = other.to_ruby if other.is_a?(Base)
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

        reader = registration = nil
        reader = context.read do
          selector = stream_selector(key)
          if %i[array linked_array].include?(kind) && (selector.negative? || selector >= size)
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
                                      transaction: context.transaction)
            if %i[array linked_array].include?(kind)
              collection.assign(collection.size, Core::Slot.null) while collection.size < selector
            end
            collection.assign(selector, stored)
          end
          context.replace_location(entry_path(selector))
          context.change_membership(path) unless present
          result
        end
      end

      protected

      def clear_entries
        collection = adapter
        needed = collection.respond_to?(:clear_needed?) ? collection.clear_needed? : !collection.size.zero?
        return false unless needed

        edit do |current|
          if current.respond_to?(:clear)
            current.clear
          else
            current.each_entry { |selector, _| current.delete(selector) }
          end
        end
        true
      end

      def edit(**options)
        context.mutate(path, **options) do |cursor|
          collection = context.profile.container(cursor.slot, context: context, path: path)
          yield collection
          cursor.replace(collection.slot)
        end
      end

      def stream_selector(key)
        check!
        case kind
        when :map, :sorted_map
          context.profile.key_bytes(key)
          key.is_a?(String) ? key.dup.freeze : key
        when :array, :linked_array then normalize_index(key)
        else raise TypeError, "byte streams require a map or array view"
        end
      end

      def stream_mutation(selector)
        if %i[array linked_array].include?(kind)
          {positions: [size, selector].min..selector}
        else
          {targets: [entry_path(selector)]}
        end
      end

      def integer_argument(value)
        result = ::Integer.try_convert(value) || raise(TypeError, "no implicit conversion of #{value.class} into Integer")
        unless result >= -LONG_MAX - 1 && result <= LONG_MAX
          raise RangeError, "integer too big to convert into long"
        end
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

      def each_entries(entries)
        iterator = nil
        generation = nil
        exhausted = false
        while true
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
              selector, stored = iterator.next
            rescue StopIteration
              exhausted = true
              next
            end
            if %i[set sorted_set].include?(kind)
              [selector]
            else
              # Transaction entries resolve again so replacement values stay live.
              stored = adapter.lookup(selector) if context.transaction
              value = context.profile.decode(stored, context: context, path: entry_path(selector))
              %i[map sorted_map].include?(kind) ? [selector, value] : [value]
            end
          end
          break if exhausted

          yield(*values)
        end
        self
      end
    end
  end
end
