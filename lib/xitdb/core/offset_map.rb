# frozen_string_literal: true

require "tempfile"

module XitDB
  module Core
    class OffsetMap
      CACHE_LIMIT = 16_384

      attr_reader :peak_cache_size

      def initialize
        @cache = {}
        @peak_cache_size = 0
      end

      def fetch(offset)
        raise ClosedError, "offset map is closed" if @closed

        @map ? @map.get(key(offset))&.value : @cache[offset]
      end

      def store(offset, target)
        raise ClosedError, "offset map is closed" if @closed

        spill if !@map && @cache.size == CACHE_LIMIT && !@cache.key?(offset)
        if @map
          @map.put(key(offset), key: Slot.new, value: Slot.uint(target))
        else
          @cache[offset] = target
          @peak_cache_size = [@peak_cache_size, @cache.size].max
        end
        target
      end

      def close
        return if @closed

        @closed = true
        @cache.clear
        @transaction&.expire!
        begin
          @store&.close
        ensure
          @temporary&.close!
        end
        nil
      end

      private

      def key(offset)
        [offset].pack("Q>")
      end

      def spill
        @temporary = Tempfile.new("xitdb-offset-map-")
        @store = FileStore.open(@temporary.path)
        @database = Database.new(store: @store, hash_size: 8, hash_id: "offs")
        # The scratch file is private and never published. One transaction keeps
        # every mapping available without a commit and fsync for each insertion.
        @transaction = Transaction.new(@database, @store, Slot.new)
        @map = HashMap.new(@transaction.root)
        @cache.each { |offset, target| @map.put(key(offset), key: Slot.new, value: Slot.uint(target)) }
        @cache.clear
      rescue Exception
        begin
          close
        rescue Exception
          nil
        end
        raise
      end
    end
  end
end
