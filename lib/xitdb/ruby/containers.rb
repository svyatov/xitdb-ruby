# frozen_string_literal: true

require_relative "ordered_keys"

module XitDB
  module Ruby
    # Maintains Ruby collection envelopes and their storage indexes.
    class Containers
      MARKERS = { array: 0x52420101, linked_array: 0x52420102, map: 0x52420103, set: 0x52420104,
                  sorted_map: 0x52420105, sorted_set: 0x52420106 }.freeze
      KEY_KINDS = { string: 1, integer: 2, float: 3, time: 4 }.freeze

      attr_reader :kind, :cursor

      def initialize(profile, cursor, context:, path:, kind: nil, key_kind: nil)
        @profile = profile
        @cursor = cursor
        @context = context
        @path = path
        if kind
          @kind = kind
          @key_kind = key_kind
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

      def empty?
        size.zero?
      end

      def lookup(selector)
        if sorted?
          bytes = key_bytes(selector)
          stored = sorted_collection.get(bytes)
          return sorted_entry(bytes, stored).last if stored

          return nil
        end
        return sequence_collection.get(index_selector(selector)) unless ordered?

        bytes = key_bytes(selector)
        return nil unless @envelope

        record_for(@profile.hasher.digest(bytes), expected_bytes: bytes)&.get(1)
      end

      def assign(selector, stored)
        if sorted?
          assign_sorted(selector, stored)
        elsif ordered?
          assign_ordered(selector, stored)
        elsif selector == size
          sequence_collection.append(stored)
        else
          sequence_collection.put(index_selector(selector),
                                  stored)
        end
        publish
      end

      def delete(selector)
        if sorted?
          bytes = key_bytes(selector)
          stored = sorted_collection.get(bytes)
          return self unless stored

          sorted_entry(bytes, stored)
          sorted_collection.remove(bytes)
        elsif ordered?
          bytes = key_bytes(selector)
          digest = @profile.hasher.digest(bytes)
          record = record_for(digest, expected_bytes: bytes)
          return self unless record

          @order.remove([fetch_slot(record, 2).value].pack("Q>"))
          @lookup.remove(digest)
        elsif kind == :linked_array
          linked_collection.delete_at(index_selector(selector))
        else
          delete_array(selector)
        end
        publish
      end

      def clear_needed?
        size.positive? || (ordered? && @next_id&.positive? == true)
      end

      def clear
        initialize_empty
        self
      end

      def insert(index, stored)
        if kind == :linked_array
          Core::BTree.new(linked_collection.cursor).insert(index, stored)
        else
          count = size
          array_collection.append(stored)
          (count - 1).downto(index) do |position|
            array_collection.put(position + 1, required_slot(array_collection.get(position)))
          end
          array_collection.put(index, stored)
        end
        publish
      end

      def truncate(count)
        if kind == :linked_array
          @collection = linked_collection.slice(0, count)
        else
          array_collection.truncate(count)
        end
        publish
      end

      def slice(start, count)
        if kind == :linked_array
          return array([Core::Slot.uint(MARKERS.fetch(kind)),
                        linked_collection.slice(start, count).cursor.slot]).cursor.slot
        end

        output = @profile.empty_container(kind, context: @context, path: @path)
        count.times { |index| output.assign(index, required_slot(lookup(start + index))) }
        output.slot
      end

      def concat(other)
        if kind == :linked_array && other.is_a?(Containers) && other.kind == :linked_array
          @collection = linked_collection.concat(other.linked_collection)
          publish
        else
          other.each_entry { |_index, stored| assign(size, stored) }
        end
        self
      end

      def each_from_index(index, &block)
        return enum_for(:each_from_index, index) unless block

        index += size if index.negative?
        return self unless index >= 0 && index < size

        each_normalized_index(index, &block)
        self
      end

      def each_normalized_index(index)
        if sorted?
          sorted_collection.each_from_index(index) do |bytes, stored|
            key, value = sorted_entry(bytes, stored)
            yield key, value
          end
        elsif kind == :linked_array
          linked_collection.each_from_index(index).with_index(index) { |stored, position| yield position, stored }
        else
          (index...size).each { |position| yield position, required_slot(lookup(position)) }
        end
        self
      end
      private :each_normalized_index

      def each_entry
        return enum_for(:each_entry) unless block_given?
        return self unless @envelope

        if sorted?
          sorted_collection.each do |bytes, stored|
            key, value = sorted_entry(bytes, stored)
            yield key, value
          end
        elsif ordered?
          @order.each do |id_bytes, hash_slot|
            key, stored = ordered_entry(id_bytes, hash_slot)
            yield key, stored
          end
        else
          sequence_collection.each.with_index { |stored, index| yield index, stored }
        end
        self
      end

      def rank(selector)
        sorted_collection.rank(key_bytes(selector))
      end

      def each_from(selector)
        return enum_for(:each_from, selector) unless block_given?

        sorted_collection.each_from(key_bytes(selector)) do |bytes, stored|
          key, value = sorted_entry(bytes, stored)
          yield key, value
        end
        self
      end

      def selector_identity(selector)
        %i[array linked_array].include?(kind) ? selector : key_bytes(selector)
      end

      protected

      attr_reader :collection

      def linked_collection
        collection = @collection
        invalid! unless collection.is_a?(Core::LinkedArrayList)

        collection
      end

      private

      def index_selector(selector)
        raise TypeError, "index must be an Integer" unless selector.is_a?(Integer)

        selector
      end

      def required_slot(slot)
        invalid! unless slot

        slot
      end

      def fetch_slot(collection, index)
        required_slot(collection.get(index))
      end

      def envelope
        value = @envelope
        invalid! unless value

        value
      end

      def declared_key_kind
        value = @key_kind
        invalid! unless value

        value
      end

      def array_collection
        collection = @collection
        invalid! unless collection.is_a?(Core::ArrayList)

        collection
      end

      def sorted_collection
        collection = @collection
        invalid! unless collection.is_a?(Core::SortedMap)

        collection
      end

      def sequence_collection
        collection = @collection
        invalid! unless collection.is_a?(Core::ArrayList) || collection.is_a?(Core::LinkedArrayList)

        collection
      end

      def ordered?
        %i[map set].include?(kind)
      end

      def sorted?
        %i[sorted_map sorted_set].include?(kind)
      end

      def array(fields)
        output = Core::ArrayList.new(@context.cursor(Core::Slot.new))
        fields.each { |field| output.append(field) }
        output
      end

      def initialize_empty
        marker = Core::Slot.uint(MARKERS.fetch(kind))
        if sorted?
          @collection = Core::SortedMap.new(@context.cursor(Core::Slot.new))
          @envelope = array([marker, Core::Slot.uint(KEY_KINDS.fetch(@key_kind)), @collection.cursor.slot])
        elsif ordered?
          @next_id = 0
          @lookup = Core::HashMap.new(@context.cursor(Core::Slot.new), counted: true)
          @order = Core::SortedMap.new(@context.cursor(Core::Slot.new))
          @envelope = array([marker, Core::Slot.uint(0), @lookup.cursor.slot, @order.cursor.slot])
        else
          klass = kind == :array ? Core::ArrayList : Core::LinkedArrayList
          @collection = klass.new(@context.cursor(Core::Slot.new))
          @envelope = array([marker, @collection.cursor.slot])
        end
        cursor.replace(envelope.cursor.slot)
      end

      def read_envelope
        @envelope = Core::ArrayList.new(cursor)
        marker = fetch_slot(envelope, 0)
        invalid! unless marker.tag == :uint && (@kind = MARKERS.key(marker.value))
        invalid! unless envelope.size == envelope_size
        if sorted?
          read_sorted_envelope
        elsif ordered?
          read_ordered_envelope
        else
          read_sequence_envelope
        end
      end

      def publish
        if sorted?
          envelope.put(2, @collection.cursor.slot)
        elsif ordered?
          envelope.put(1, Core::Slot.uint(@next_id))
          envelope.put(2, @lookup.cursor.slot)
          envelope.put(3, @order.cursor.slot)
        else
          envelope.put(1, @collection.cursor.slot)
        end
        cursor.replace(envelope.cursor.slot)
        self
      end

      def key_bytes(selector)
        sorted? ? OrderedKeys.dump(selector, kind: declared_key_kind) : @profile.key_bytes(selector)
      rescue ValueError => e
        raise e.class.new(e.message, path: @path + [selector]), cause: e
      end

      def raw_bytes(slot)
        invalid! unless slot && %i[bytes short_bytes].include?(slot.tag)
        value = @context.database.core.read_bytes(slot, bound: @context.read_bound)
        invalid! if value.format_tag
        value.bytes
      end

      def decode_key(slot)
        value = Scalars.decode(slot, core: @context.database.core, bound: @context.read_bound)
        case value
        when String, Integer, Float, Time, Symbol, true, false, nil, UInt then value
        else invalid!
        end
      end

      def record_for(digest, expected_bytes: nil)
        stored = @lookup.get(digest)
        return nil unless stored

        invalid! unless stored.tag == :array_list
        record = Core::ArrayList.new(@context.cursor(stored))
        invalid! unless record.size == 3
        id = fetch_slot(record, 2)
        invalid! unless id.tag == :uint && id.value < @next_id
        validate_record(record, digest, id, expected_bytes)
        record
      end

      def sorted_entry(bytes, stored)
        if kind == :sorted_map
          invalid! unless stored.tag == :array_list
          record = Core::ArrayList.new(@context.cursor(stored))
          invalid! unless record.size == 2
          original = fetch_slot(record, 0)
          value = fetch_slot(record, 1)
        else
          original = stored
          value = Core::Slot.null
        end
        key = decode_key(original)
        begin
          invalid! unless OrderedKeys.dump(key, kind: declared_key_kind) == bytes
        rescue UnsupportedValueError, UnsupportedEncodingError
          invalid!
        end
        [key, value]
      end

      def assign_sorted(selector, stored)
        bytes = key_bytes(selector)
        previous = sorted_collection.get(bytes)
        if previous
          sorted_entry(bytes, previous)
          original = kind == :sorted_set ? previous : fetch_slot(Core::ArrayList.new(@context.cursor(previous)), 0)
        else
          original = @profile.encode_scalar(selector, core: @context.database.core)
        end
        value = kind == :sorted_set ? original : array([original, stored]).cursor.slot
        sorted_collection.put(bytes, value: value)
      end

      def assign_ordered(selector, stored)
        bytes = key_bytes(selector)
        initialize_empty unless @envelope
        digest = @profile.hasher.digest(bytes)
        previous = record_for(digest, expected_bytes: bytes)
        if previous
          record = array([fetch_slot(previous, 0), kind == :set ? Core::Slot.null : stored, fetch_slot(previous, 2)])
        else
          raise RangeError, "insertion identifier exhausted" if @next_id == Core::Format::UINT64_MAX

          key = @profile.encode_scalar(selector, core: @context.database.core)
          record = array([key, kind == :set ? Core::Slot.null : stored, Core::Slot.uint(@next_id)])
          @order.put([@next_id].pack("Q>"), value: @context.database.core.bytes(digest))
          @next_id += 1
        end
        @lookup.put(digest, key: @context.database.core.bytes(bytes), value: record.cursor.slot)
      end

      def delete_array(selector)
        count = size
        unless selector.is_a?(Integer) && selector >= 0 && selector < count
          raise IndexError,
                "array index outside list"
        end

        (selector...(count - 1)).each do |index|
          array_collection.put(index, required_slot(array_collection.get(index + 1)))
        end
        array_collection.truncate(count - 1)
      end

      def envelope_size
        return 4 if ordered?

        sorted? ? 3 : 2
      end

      def read_sequence_envelope
        child = fetch_slot(envelope, 1)
        expected = kind == :array ? :array_list : :linked_array_list
        invalid! unless child.tag == expected
        klass = kind == :array ? Core::ArrayList : Core::LinkedArrayList
        @collection = klass.new(@context.cursor(child))
      end

      def read_sorted_envelope
        key = fetch_slot(envelope, 1)
        child = fetch_slot(envelope, 2)
        invalid! unless key.tag == :uint && (@key_kind = KEY_KINDS.key(key.value)) && child.tag == :sorted_map
        @collection = Core::SortedMap.new(@context.cursor(child))
      end

      def read_ordered_envelope
        id = fetch_slot(envelope, 1)
        lookup = fetch_slot(envelope, 2)
        order = fetch_slot(envelope, 3)
        invalid! unless id.tag == :uint && lookup.tag == :counted_hash_map && order.tag == :sorted_map
        @next_id = id.value
        @lookup = Core::HashMap.new(@context.cursor(lookup), counted: true)
        @order = Core::SortedMap.new(@context.cursor(order))
        invalid! unless @lookup.size == @order.size && @lookup.size <= @next_id
      end

      def ordered_entry(id_bytes, hash_slot)
        invalid! unless id_bytes.bytesize == 8
        digest = raw_bytes(hash_slot)
        invalid! unless digest.bytesize == 32
        record = record_for(digest)
        invalid! unless record && fetch_slot(record, 2).value == id_bytes.unpack1("Q>")
        [decode_key(fetch_slot(record, 0)), fetch_slot(record, 1)]
      end

      def validate_record(record, digest, id, expected_bytes)
        bytes = raw_bytes(@lookup.key(digest))
        invalid! unless @profile.hasher.digest(bytes) == digest && (!expected_bytes || bytes == expected_bytes)
        begin
          invalid! unless @profile.key_bytes(decode_key(fetch_slot(record, 0))) == bytes
        rescue UnsupportedValueError
          invalid!
        end
        invalid! unless raw_bytes(@order.get([id.value].pack("Q>"))) == digest
        invalid! if kind == :set && fetch_slot(record, 1) != Core::Slot.null
      end

      def invalid!
        raise InvalidValueError, "invalid Ruby container envelope or index record"
      end
    end
  end
end
