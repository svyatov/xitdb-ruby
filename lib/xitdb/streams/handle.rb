# frozen_string_literal: true

module XitDB
  module Streams
    # Restricts stream access to the lifetime of its owning block.
    # @api private
    class Handle
      # Bind a stream handle to the snapshot or transaction that owns its bytes.
      # @api private
      # @param context [Context]
      def initialize(context)
        @context = context
        @active = true
      end

      # Forbid further stream access after its block ends.
      # @api private
      # @return [void]
      def expire!
        @active = false
      end

      private

      # Require both a live stream block and a usable database context.
      # @return [void]
      # @raise [ExpiredViewError] if the stream block has ended
      def check!
        raise ExpiredViewError, "byte stream block has ended" unless @active

        @context.check!
      end

      # Convert an IO argument to a bounded native integer.
      # @param value [Object]
      # @return [Integer]
      def integer!(value)
        result = Integer.try_convert(value) || raise(TypeError, "expected an Integer")
        limit = (1 << ((0.size * 8) - 1)) - 1
        raise RangeError, "integer too big to convert into long" unless result.between?(-limit - 1, limit)

        result
      end
    end
  end
end
