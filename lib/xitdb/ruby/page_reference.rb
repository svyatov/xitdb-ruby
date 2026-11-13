# frozen_string_literal: true

module XitDB
  module Ruby
    # Carries a row location without retaining decoded values.
    # @api private
    class PageReference < Core::Slot
      attr_reader :page, :index, :count

      def initialize(page, index, count)
        @page = page
        @index = index
        @count = count
        super(tag: :record, value: page.value)
      end

      def ==(other)
        other.is_a?(PageReference) && page == other.page && index == other.index && count == other.count
      end

      def to_bytes
        raise InvalidValueError, "persist page reference before serialization"
      end
    end
  end
end
