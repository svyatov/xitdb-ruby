# frozen_string_literal: true

module XitDB
  module Ruby
    class Containers
      MARKERS = {array: 0x52420101, linked_array: 0x52420102, map: 0x52420103, set: 0x52420104}.freeze

      attr_reader :kind, :cursor

      def initialize(profile, cursor, context:, path:, kind: nil)
        @profile, @cursor, @context, @path = profile, cursor, context, path
        if kind
          @kind = kind
          initialize_empty
        elsif cursor.slot.empty?
          @kind = :map
        else
          read_envelope
        end
      end

      def slot
        cursor.slot
      end

      def size
        return 0 unless @envelope

        ordered? ? @lookup.size : @collection.size
      end

      def lookup(selector)
        return @collection.get(selector) unless ordered?

        bytes = key_bytes(selector)
        return nil unless @envelope

        record_for(@profile.hasher.digest(bytes), expected_bytes: bytes)&.get(1)
      end

      def assign(selector, stored)
        if ordered?
          bytes = key_bytes(selector)
          initialize_empty unless @envelope
          digest = @profile.hasher.digest(bytes)
          previous = record_for(digest, expected_bytes: bytes)
          if previous
            record = array([previous.get(0), kind == :set ? Core::Slot.null : stored, previous.get(2)])
          else
            raise RangeError, "insertion identifier exhausted" if @next_id == Core::Format::UINT64_MAX

            key = @profile.encode_scalar(selector, core: @context.database.core)
            record = array([key, kind == :set ? Core::Slot.null : stored, Core::Slot.uint(@next_id)])
            @order.put([@next_id].pack("Q>"), value: @context.database.core.bytes(digest))
            @next_id += 1
          end
          @lookup.put(digest, key: @context.database.core.bytes(bytes), value: record.cursor.slot)
        else
          selector == size ? @collection.append(stored) : @collection.put(selector, stored)
        end
        publish
      end

      def delete(selector)
        if ordered?
          bytes = key_bytes(selector)
          digest = @profile.hasher.digest(bytes)
          record = record_for(digest, expected_bytes: bytes)
          return self unless record

          @order.remove([record.get(2).value].pack("Q>"))
          @lookup.remove(digest)
        elsif kind == :linked_array
          @collection.delete_at(selector)
        else
          count = size
          raise IndexError, "array index outside list" unless selector.is_a?(Integer) && selector >= 0 && selector < count

          (selector...(count - 1)).each { |index| @collection.put(index, @collection.get(index + 1)) }
          @collection.truncate(count - 1)
        end
        publish
      end

      def clear_needed?
        size.positive? || (ordered? && @next_id && @next_id.positive?)
      end

      def clear
        initialize_empty
        self
      end

      def insert(index, stored)
        if kind == :linked_array
          Core::BTree.new(@collection.cursor).insert(index, stored)
        else
          count = size
          @collection.append(stored)
          (count - 1).downto(index) { |position| @collection.put(position + 1, @collection.get(position)) }
          @collection.put(index, stored)
        end
        publish
      end

      def truncate(count)
        if kind == :linked_array
          @collection = @collection.slice(0, count)
        else
          @collection.truncate(count)
        end
        publish
      end

      def slice(start, count)
        if kind == :linked_array
          return array([Core::Slot.uint(MARKERS.fetch(kind)), @collection.slice(start, count).cursor.slot]).cursor.slot
        end

        output = @profile.empty_container(kind, context: @context, path: @path)
        count.times { |index| output.assign(index, lookup(start + index)) }
        output.slot
      end

      def concat(other)
        if kind == :linked_array && other.kind == :linked_array
          @collection = @collection.concat(other.collection)
          publish
        else
          other.each_entry { |_index, stored| assign(size, stored) }
        end
        self
      end

      def each_from_index(index)
        return enum_for(__method__, index) unless block_given?

        index += size if index.negative?
        return self unless index >= 0 && index < size

        if kind == :linked_array
          @collection.each_from_index(index).with_index(index) { |stored, position| yield position, stored }
        else
          (index...size).each { |position| yield position, lookup(position) }
        end
        self
      end

      def each_entry
        return enum_for(__method__) unless block_given?
        return self unless @envelope

        if ordered?
          @order.each do |id_bytes, hash_slot|
            invalid! unless id_bytes.bytesize == 8
            digest = raw_bytes(hash_slot)
            invalid! unless digest.bytesize == 32
            record = record_for(digest)
            invalid! unless record && record.get(2).value == id_bytes.unpack1("Q>")
            yield decode_key(record.get(0)), record.get(1)
          end
        else
          @collection.each.with_index { |stored, index| yield index, stored }
        end
        self
      end

      protected

      attr_reader :collection

      private

      def ordered?
        kind == :map || kind == :set
      end

      def array(fields)
        output = Core::ArrayList.new(@context.cursor(Core::Slot.new))
        fields.each { |field| output.append(field) }
        output
      end

      def initialize_empty
        marker = Core::Slot.uint(MARKERS.fetch(kind))
        if ordered?
          @next_id = 0
          @lookup = Core::HashMap.new(@context.cursor(Core::Slot.new), counted: true)
          @order = Core::SortedMap.new(@context.cursor(Core::Slot.new))
          @envelope = array([marker, Core::Slot.uint(0), @lookup.cursor.slot, @order.cursor.slot])
        else
          klass = kind == :array ? Core::ArrayList : Core::LinkedArrayList
          @collection = klass.new(@context.cursor(Core::Slot.new))
          @envelope = array([marker, @collection.cursor.slot])
        end
        cursor.replace(@envelope.cursor.slot)
      end

      def read_envelope
        @envelope = Core::ArrayList.new(cursor)
        marker = @envelope.get(0)
        invalid! unless marker&.tag == :uint && (@kind = MARKERS.key(marker.value))
        invalid! unless @envelope.size == (ordered? ? 4 : 2)
        if ordered?
          id, lookup, order = (1..3).map { |index| @envelope.get(index) }
          invalid! unless id.tag == :uint && lookup.tag == :counted_hash_map && order.tag == :sorted_map
          @next_id = id.value
          @lookup = Core::HashMap.new(@context.cursor(lookup), counted: true)
          @order = Core::SortedMap.new(@context.cursor(order))
          invalid! unless @lookup.size == @order.size && @lookup.size <= @next_id
        else
          child = @envelope.get(1)
          expected = kind == :array ? :array_list : :linked_array_list
          invalid! unless child.tag == expected
          klass = kind == :array ? Core::ArrayList : Core::LinkedArrayList
          @collection = klass.new(@context.cursor(child))
        end
      end

      def publish
        if ordered?
          @envelope.put(1, Core::Slot.uint(@next_id))
          @envelope.put(2, @lookup.cursor.slot)
          @envelope.put(3, @order.cursor.slot)
        else
          @envelope.put(1, @collection.cursor.slot)
        end
        cursor.replace(@envelope.cursor.slot)
        self
      end

      def key_bytes(selector)
        @profile.key_bytes(selector)
      rescue ValueError => error
        raise error.class.new(error.message, path: @path + [selector]), cause: error
      end

      def raw_bytes(slot)
        invalid! unless slot && %i[bytes short_bytes].include?(slot.tag)
        value = @context.database.core.read_bytes(slot, bound: @context.read_bound)
        invalid! if value.format_tag
        value.bytes
      end

      def decode_key(slot)
        Scalars.decode(slot, core: @context.database.core, bound: @context.read_bound)
      end

      def record_for(digest, expected_bytes: nil)
        stored = @lookup.get(digest)
        return nil unless stored

        invalid! unless stored.tag == :array_list
        record = Core::ArrayList.new(@context.cursor(stored))
        invalid! unless record.size == 3
        id = record.get(2)
        invalid! unless id.tag == :uint && id.value < @next_id
        bytes = raw_bytes(@lookup.key(digest))
        invalid! unless @profile.hasher.digest(bytes) == digest && (!expected_bytes || bytes == expected_bytes)
        begin
          invalid! unless @profile.key_bytes(decode_key(record.get(0))) == bytes
        rescue UnsupportedValueError
          invalid!
        end
        invalid! unless raw_bytes(@order.get([id.value].pack("Q>"))) == digest
        invalid! if kind == :set && record.get(1) != Core::Slot.null
        record
      end

      def invalid!
        raise InvalidValueError, "invalid Ruby container envelope or index record"
      end
    end
  end
end
