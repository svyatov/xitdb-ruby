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

        magic = body.byteslice(0, 4)
        raise InvalidValueError, "compact page magic" unless %w[XR01 XF01 XA01].include?(magic)

        body[0, 4] = "XP01"
        super(body, expected)
        @padded = magic == "XA01"
        read_layout(magic != "XR01")
        @position = @payload
      end

      def row(index)
        raise IndexError, "row outside page" unless index.between?(0, @count - 1)

        left = offset(index)
        right = offset(index + 1)
        raise InvalidValueError, "compact row offsets" unless right.between?(left, @length)

        @position = @payload + left
        framed_row(@payload + right)
      end

      def page
        if (stride = @stride)
          @position = @payload
          return ::Array.new(@count) do |index|
            framed_row(@payload + ((index + 1) * stride))
          end
        end

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

      def verify_frame!(index)
        finish_frame!(@payload + offset(index + 1))
      end

      def framed_row(bound)
        result = read_row
        finish_frame!(bound)
        result
      end

      def finish_frame!(bound)
        if @padded
          while @position < bound
            raise InvalidValueError, "invalid row padding" unless byte.zero?
          end
        end
        raise InvalidValueError, "compact row framing" unless @position == bound
      end

      def read_layout(fixed)
        @directory = @position
        @payload = fixed ? @directory : @directory + ((@count + 1) * 2)
        @length = @bytes.bytesize - @payload
        if fixed
          @stride, remainder = @length.divmod(@count)
          raise InvalidValueError, "compact page stride" unless remainder.zero?
        elsif @length.negative? || !offset(0).zero? || offset(@count) != @length
          raise InvalidValueError, "compact page directory"
        end
      end

      def offset(index)
        stride = @stride
        return index * stride if stride

        Integer(@bytes.unpack1("S<", offset: @directory + (index * 2)))
      end
    end
  end
end
