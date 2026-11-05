# frozen_string_literal: true

require "tempfile"

module XitDB
  module Core
    # Tracks copied offsets and spills large maps to a temporary store.
    class OffsetMap
      CACHE_LIMIT = 16_384

      attr_reader :peak_cache_size

      def initialize
        @cache = {}
        @peak_cache_size = 0
      end

      def fetch(offset)
        raise ClosedError, "offset map is closed" if @closed

        map = @map
        map ? map.get(key(offset))&.value : @cache[offset]
      end

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

      def key(offset)
        [offset].pack("Q>")
      end

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
