# frozen_string_literal: true

module XitDB
  module Core
    module Bytes
      # An immutable reader for one byte payload within a fixed database boundary.
      # @api private
      class Source
        # @!attribute [r] size
        #   Declared number of payload or digest bytes.
        #   @return [Integer]
        # @!attribute [r] format_tag
        #   Optional frozen two-byte application format identifier.
        #   @return [String, nil]
        attr_reader :size, :format_tag

        # Builds a frozen reader limited to one payload and storage boundary.
        # @param database [Database] database that owns the stored records
        # @param location [String, Integer] inline payload bytes or absolute payload offset
        # @param size [Integer] number of bytes
        # @param format_tag [String, nil] optional two-byte application format identifier
        # @param bound [Integer] exclusive upper byte boundary for reads
        # @return [Source]
        def initialize(database, location, size, format_tag, bound)
          @database = database
          @location = location
          @size = size
          @format_tag = format_tag
          @bound = bound
          freeze
        end

        # Reads an exact range inside this payload.
        # @param position [Integer] zero-based byte offset inside the payload
        # @param length [Integer] number of bytes
        # @return [String]
        # @raise [InvalidValueError] if the requested range exceeds the payload
        # @raise [TypeError] if position or length is not an Integer
        def read(position, length)
          @database.check_open!
          unless position.is_a?(Integer) && length.is_a?(Integer)
            raise TypeError, "byte positions and lengths must be Integers"
          end
          if position.negative? || length.negative? || position + length > size
            raise InvalidValueError, "truncated byte payload"
          end

          location = @location
          if location.is_a?(String)
            Format.slice(location, position, length)
          else
            @database.read_at(location + position, length, bound: @bound)
          end
        end
      end
      private_constant :Source
    end
  end
end
