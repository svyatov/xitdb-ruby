# frozen_string_literal: true

require "tempfile"

module XitDB
  module Core
    # A source-to-destination offset table used while copying records.
    #
    # It starts in memory and moves to a temporary database after CACHE_LIMIT entries.
    # @api private
    class OffsetMap
      # Maximum distinct offset mappings retained in memory before a temporary store is created.
      CACHE_LIMIT = 16_384

      # Largest number of offset entries held in the in-memory cache.
      # @return [Integer]
      attr_reader :peak_cache_size

      # Starts an offset lookup table in memory.
      # @return [OffsetMap]
      def initialize
        @cache = {}
        @peak_cache_size = 0
      end

      # Finds the copied destination for a source offset.
      # @param offset [Integer] absolute byte offset
      # @return [Integer, nil]
      # @raise [ClosedError] if the offset map has been closed
      def fetch(offset)
        raise ClosedError, "offset map is closed" if @closed

        map = @map
        map ? map.get(key(offset))&.value : @cache[offset]
      end

      # Records a destination, spilling to a temporary database when the cache fills.
      # @param offset [Integer] absolute byte offset
      # @param target [Integer] absolute destination byte offset
      # @return [Integer]
      # @raise [ClosedError] if the offset map has been closed
      def store(offset, target)
        raise ClosedError, "offset map is closed" if @closed

        spill if !@map && @cache.size == CACHE_LIMIT && !@cache.key?(offset)
        map = @map
        if map
          map.put(key(offset), key: Slot.new, value: Slot.uint(target))
        else
          @cache[offset] = target
          @peak_cache_size = [@peak_cache_size, @cache.size].max
        end
        target
      end

      # Releases the cache and closes and deletes its temporary backing file.
      # @return [nil]
      def close
        return if @cleanup_complete

        @closed = true
        @cache.clear
        @transaction&.expire!
        begin
          @store&.close(discard: true)
        ensure
          @temporary&.close!
        end
        @cleanup_complete = true
        nil
      end

      private

      # Encodes a source offset as an unsigned 64-bit binary map key.
      def key(offset)
        [offset].pack("Q>")
      end

      # Moves cached offsets to a private file-backed map in one scratch transaction.
      def spill
        temporary = Tempfile.new("xitdb-offset-map-")
        @temporary = temporary
        store = FileStore.open(temporary.path || raise(IOError, "temporary file has no path"))
        @store = store
        database = Database.new(store: store, hash_size: 8, hash_id: "offs")
        @database = database
        # The scratch file is private and never published. One transaction keeps
        # every mapping available without a commit and fsync for each insertion.
        transaction = Transaction.new(database, store, Slot.new)
        @transaction = transaction
        map = HashMap.new(transaction.root)
        @map = map
        @cache.each { |offset, target| map.put(key(offset), key: Slot.new, value: Slot.uint(target)) }
        @cache.clear
      rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
        begin
          close
        rescue Exception # rubocop:disable Lint/RescueException -- Cleanup must also preserve nonstandard exceptions.
          nil
        end
        raise
      end
    end
  end
end
