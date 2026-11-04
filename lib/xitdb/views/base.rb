# frozen_string_literal: true

module XitDB
  module Views
    class Base
      include Enumerable

      attr_reader :context, :path, :kind

      def initialize(context:, path:, kind:)
        @context = context
        @path = path.map { |selector| selector.is_a?(String) ? selector.dup.freeze : selector }.freeze
        @kind = kind
        @generations = context.generations(@path)
      end

      def check!
        context.check!
        unless context.generations(path) == @generations
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

        check!
        generation = context.membership(path)
        adapter.each_entry do |selector, stored|
          check!
          if context.membership(path) != generation
            raise ConcurrentModificationError, "collection membership changed during iteration"
          end
          if %i[set sorted_set].include?(kind)
            yield selector
          else
            # Transaction entries resolve again so replacement values stay live.
            stored = adapter.lookup(selector) if context.transaction
            value = context.profile.decode(stored, context: context, path: path + [selector])
            %i[map sorted_map].include?(kind) ? yield(selector, value) : yield(value)
          end
        end
        self
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
    end
  end
end
