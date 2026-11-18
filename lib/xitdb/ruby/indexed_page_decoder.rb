# frozen_string_literal: true

require "digest"

module XitDB
  module Ruby
    # Checks page integrity and decodes independently framed compact rows.
    # @api private
    class IndexedPageDecoder < PageDecoder
      def initialize(bytes, expected)
        raise TypeError, "page must be a String" unless Object.instance_method(:is_a?).bind_call(bytes, String)

        # @type var source: String
        source = String.instance_method(:byteslice).bind_call(bytes, 0, PageCodec::PAGE_LIMIT + 1)
        source = source.b
        raise InvalidValueError, "compact page byte limit" unless source.bytesize.between?(38, PageCodec::PAGE_LIMIT)

        body = source.byteslice(0, source.bytesize - 32) || raise(InvalidValueError, "compact page body")
        raise InvalidValueError, "compact page checksum" unless Digest::SHA256.digest(body) == source.byteslice(-32, 32)
        raise InvalidValueError, "compact page magic" unless body.byteslice(0, 4) == "XR01"

        body[0, 4] = "XP01"
        super(body, expected)
        @directory = @position
        @payload = @directory + ((@count + 1) * 2)
        @length = @bytes.bytesize - @payload
        return if @length >= 0 && offset(0).zero? && offset(@count) == @length

        raise InvalidValueError, "compact page directory"
      end

      def row(index)
        raise IndexError, "row outside page" unless index.between?(0, @count - 1)

        # @type var positions: Array[Integer]
        positions = (@bytes.byteslice(@directory + (index * 2),
                                      4) || raise(InvalidValueError, "compact row offsets")).unpack("S<2")
        left = positions.fetch(0)
        right = positions.fetch(1)
        raise InvalidValueError, "compact row offsets" unless right.between?(left, @length)

        @position = @payload + left
        result = read_row
        raise InvalidValueError, "compact row framing" unless @position == @payload + right

        result
      end

      def page
        # @type var positions: Array[Integer]
        positions = (@bytes.byteslice(@directory,
                                      (@count + 1) * 2) || raise(InvalidValueError,
                                                                 "compact page directory")).unpack("S<*")
        @position = @payload
        rows = ::Array.new(@count) do |index|
          raise InvalidValueError, "compact row framing" unless @position == @payload + positions.fetch(index)

          read_row
        end
        finish!
        rows
      end

      private

      def offset(index)
        Integer((@bytes.byteslice(@directory + (index * 2),
                                  2) || raise(InvalidValueError, "compact page directory")).unpack1("S<"))
      end
    end
  end
end
