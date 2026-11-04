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
        check!
        context.resolve(path)
      end

      def adapter
        context.profile.container(slot, context: context, path: path)
      end

      def size
        adapter.size
      end

      def empty?
        size.zero?
      end

      def each
        return enum_for(__method__) unless block_given?

        each_entries(adapter.each_entry) { |*entry| yield(*entry) }
      end

      def slot_for_assignment(context:, path:)
        slot
      end

      def to_ruby
        ValueWalker.materialize(self)
      end

      def ==(other)
        other = other.to_ruby if other.is_a?(Base)
        to_ruby == other
      end

      def inspect
        location = path.first(4).map { |selector| selector.is_a?(String) ? selector.byteslice(0, 32) : selector }
        suffix = path.size > 4 ? "..." : ""
        "#<#{self.class} profile=#{context.profile.class.name} path=#{location.inspect}#{suffix}>"
      end

      protected

      def edit
        context.mutate(path) do |cursor|
          collection = context.profile.container(cursor.slot, context: context, path: path)
          yield collection
          cursor.replace(collection.slot)
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
                    transaction: context.transaction, readonly: readonly)
      end

      def entry_path(selector)
        path + [selector]
      end

      def each_entries(entries)
        check!
        generation = @location&.membership
        entries.each do |selector, stored|
          check!
          if @location&.membership != generation
            raise ConcurrentModificationError, "collection membership changed during iteration"
          end
          if %i[set sorted_set].include?(kind)
            yield selector
          else
            # Transaction entries resolve again so replacement values stay live.
            stored = adapter.lookup(selector) if context.transaction
            value = context.profile.decode(stored, context: context, path: entry_path(selector))
            %i[map sorted_map].include?(kind) ? yield(selector, value) : yield(value)
          end
        end
        self
      end
    end
  end
end
