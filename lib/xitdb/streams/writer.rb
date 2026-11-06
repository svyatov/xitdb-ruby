# frozen_string_literal: true

module XitDB
  module Streams
    # Spools bytes before the enclosing assignment is published.
    class Writer < Handle
      # Attach an active context to the temporary file receiving streamed bytes.
      # @api private
      # @param context [Context]
      # @param spool [File] temporary binary file
      def initialize(context, spool)
        super(context)
        @spool = spool
      end

      # Append the value's String representation in bounded chunks.
      #
      # Successful writes still require the enclosing writer block and transaction to complete.
      # @param value [#to_s] value to convert to bytes
      # @return [Integer] number of bytes written
      def write(value)
        check!
        bytes = value.to_s
        raise TypeError, "to_s must return a String" unless bytes.is_a?(String)

        position = 0
        while position < bytes.bytesize
          check!
          chunk = bytes.byteslice(position, Core::Bytes::CHUNK_SIZE) || raise(EOFError, "byte source ended")
          position += @spool.write(chunk)
        end
        position
      end

      # Read the current byte position within the stream.
      # @return [Integer]
      def pos
        check!
        @spool.pos
      end
    end
  end
end
