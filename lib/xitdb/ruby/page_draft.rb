# frozen_string_literal: true

module XitDB
  module Ruby
    # Carries an edited row only until its parent publishes the operation.
    # @api private
    class PageDraft < Core::Slot
      attr_reader :decoded

      def initialize(decoded)
        @decoded = decoded
        super(tag: :record)
      end

      def ==(other)
        equal?(other)
      end

      def to_bytes
        raise InvalidValueError, "persist page draft before serialization"
      end
    end
  end
end
