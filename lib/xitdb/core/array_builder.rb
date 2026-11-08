# frozen_string_literal: true

module XitDB
  module Core
    # Builds an unpublished indexed list with at most sixteen slots per level.
    # The owner supplies transaction rollback and publishes the completed root.
    # @api private
    class ArrayBuilder
      def initialize(transaction)
        @transaction = transaction
        @levels = [[]]
        @count = 0
        @slot = nil
      end

      # Adds one validated element before finalization.
      def append(slot)
        @transaction.check_active!
        raise TransactionStateError, "array builder is finalized" if @slot
        raise TypeError, "expected Slot" unless slot.is_a?(Slot)
        raise CorruptionError, "unknown slot tag" unless Slot::TAGS.include?(slot.tag)
        raise InvalidValueError, "index slot is internal to array branches" if slot.tag == :index
        raise RangeError, "array size exceeds unsigned 64-bit range" if @count == Format::UINT64_MAX

        push(0, slot)
        @count += 1
        self
      end

      # Flushes partial blocks once and returns the stable completed descriptor.
      def slot
        @transaction.check_active!
        stored = @slot
        return stored if stored

        level = 0
        loop do
          fields = @levels.fetch(level)
          if @levels.drop(level + 1).all?(&:empty?)
            pointer = level.positive? && fields.size == 1 ? fields.fetch(0).value : block(fields)
            completed = Slot.new(tag: :array_list,
                                 value: @transaction.append([@count, pointer].pack("Q>Q>")))
            @slot = completed
            return completed
          end
          unless fields.empty?
            @levels[level] = []
            push(level + 1, Slot.new(tag: :index, value: block(fields)))
          end
          level += 1
        end
      end

      private

      def push(level, slot)
        loop do
          @levels[level] ||= []
          fields = @levels.fetch(level)
          fields << slot
          return unless fields.size == 16

          slot = Slot.new(tag: :index, value: block(fields))
          @levels[level] = []
          level += 1
        end
      end

      def block(fields)
        @transaction.append(fields.map(&:to_bytes).join.b.ljust(ArrayList::BLOCK_SIZE, "\0"))
      end
    end
  end
end
