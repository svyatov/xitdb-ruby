# frozen_string_literal: true

module XitDB
  # Explicit unsigned storage for an integer.
  class UInt
    # @return [Integer] unsigned value represented by this wrapper
    attr_reader :value

    # Validate and freeze an explicitly unsigned 64-bit integer.
    # @param value [Integer] integer from zero through 2**64 - 1
    # @raise [RangeError] if the integer is outside that range
    def initialize(value)
      @value = Core::Format.integer!(value, 0..Core::Format::UINT64_MAX)
      freeze
    end
  end
end
