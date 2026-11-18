# frozen_string_literal: true

module XitDB
  module Ruby
    # Holds one decoded scalar for an adapter operation.
    # @api private
    class PageCell < Core::Slot
      attr_reader :decoded

      def initialize(value)
        @decoded = value
        super(tag: 127)
      end

      def to_bytes
        raise InvalidValueError, "persist page cell before serialization"
      end
    end
  end
end
