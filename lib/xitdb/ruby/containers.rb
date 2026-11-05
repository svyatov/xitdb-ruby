# frozen_string_literal: true

require_relative "ordered_keys"

module XitDB
  module Ruby
    # Adapts Ruby-profile collections stored inside marked array envelopes.
    # An envelope records the logical kind and the roots of its native storage structures.
    # Maps and sets combine a hash lookup with a sorted insertion-identifier index to preserve insertion order.
    # Typed sorted collections store ordering bytes alongside original keys, which retain their Ruby representation.
    # Sequences wrap native array or linked-array storage. Reads validate envelope fields and index agreement.
    class Containers
      # Version-one envelope markers identifying the logical Ruby collection kind.
      MARKERS = { array: 0x52420101, linked_array: 0x52420102, map: 0x52420103, set: 0x52420104,
                  sorted_map: 0x52420105, sorted_set: 0x52420106 }.freeze
      # Version-one numeric identifiers for typed sorted-key declarations.
      KEY_KINDS = { string: 1, integer: 2, float: 3, time: 4 }.freeze

      attr_reader :kind, :cursor

      # @!attribute [r] kind
      #   Logical Ruby collection kind.
      #
      #   @return [Symbol] logical Ruby collection kind
      # @!attribute [r] cursor
      #   Cursor holding the collection envelope root.
      #
      #   @return [Core::Cursor] cursor holding the collection envelope root

      # Opens an envelope or initializes the requested empty collection.
      # An uninitialized root represents an empty Ruby map.
      #
      # @param profile [Profiles::Ruby] scalar, key, and hash rules
      # @param cursor [Core::Cursor] collection root cursor
      # @param context [Context] snapshot or transaction owner
      # @param path [Array<Object>] logical collection location
      # @param kind [Symbol, nil] explicit logical kind for a new collection
      # @param key_kind [Symbol, nil] :string, :integer, :float, or :time for typed sorted collections
      # @raise [InvalidValueError] if the stored envelope is inconsistent
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

      # Returns the collection descriptor held by the adapter cursor.
      #
      # @return [Core::Slot] current stored collection root
      def slot
        cursor.slot
      end

      # Counts the entries visible through this collection adapter.
      #
      # @return [Integer] number of keys, members, or sequence elements
      def size
        return 0 unless @envelope

        ordered? ? @lookup.size : @collection.size
      end

      # Checks whether the collection has any entries.
      #
      # @return [Boolean] true when the entry count is zero
      def empty?
        size.zero?
      end

      # Looks up a stored child without decoding its scalar or collection value.
      #
      # @param selector [Object] key, member, or zero-based sequence index
      # @return [Core::Slot, nil] stored child, or nil when absent
      # @raise [TypeError] if a sequence selector is not an Integer
      # @raise [ValueError] if the key or stored layout is invalid
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

      # Stores an encoded child at a key or sequence position.
      # A sequence position equal to size appends the child.
      #
      # @param selector [Object] key, member, or nonnegative sequence index
      # @param stored [Core::Slot] already encoded child value
      # @return [self] this adapter
      # @raise [ValueError] if the key or stored layout is invalid
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

      # Removes a key, set member, or sequence element.
      # Deleting a sequence element shifts the following positions down by one.
      #
      # @param selector [Object] key, member, or nonnegative sequence index
      # @return [self] this adapter
      # @raise [IndexError] if an array index is outside the collection
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

      # Checks whether clearing must remove entries or reset the insertion identifier counter.
      #
      # @return [Boolean] whether clearing changes stored state
      def clear_needed?
        size.positive? || (ordered? && @next_id&.positive? == true)
      end

      # Replaces the collection with an empty envelope of the same kind and key type.
      #
      # @return [self] this adapter
      def clear
        initialize_empty
        self
      end

      # Inserts a stored sequence element and shifts the following positions.
      # Array insertion copies the suffix; linked arrays follow a counted tree path.
      #
      # @param index [Integer] nonnegative insertion position validated by the caller
      # @param stored [Core::Slot] encoded element
      # @return [self] this adapter
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

      # Keeps the first count elements of a sequence.
      #
      # @param count [Integer] retained length validated by the caller
      # @return [self] this adapter
      def truncate(count)
        if kind == :linked_array
          @collection = linked_collection.slice(0, count)
        else
          array_collection.truncate(count)
        end
        publish
      end

      # Builds a stored sequence containing a contiguous range of elements.
      #
      # @param start [Integer] nonnegative start position validated by the caller
      # @param count [Integer] element count validated by the caller
      # @return [Core::Slot] descriptor of the new sequence
      def slice(start, count)
        if kind == :linked_array
          return array([Core::Slot.uint(MARKERS.fetch(kind)),
                        linked_collection.slice(start, count).cursor.slot]).cursor.slot
        end

        output = @profile.empty_container(kind, context: @context, path: @path)
        count.times { |index| output.assign(index, required_slot(lookup(start + index))) }
        output.slot
      end

      # Appends the stored elements of another sequence.
      # Two linked arrays can join through their tree structure.
      #
      # @param other [Object] sequence adapter implementing kind, cursor, and each_entry
      # @return [self] this adapter
      def concat(other)
        if kind == :linked_array && other.is_a?(Containers) && other.kind == :linked_array
          @collection = linked_collection.concat(other.linked_collection)
          publish
        else
          other.each_entry { |_index, stored| assign(size, stored) }
        end
        self
      end

      # Visits sequence or sorted entries starting at an ordinal position.
      # Negative positions count from the end; positions outside the collection visit no entries.
      #
      # @param index [Integer] starting ordinal position
      # @return [self, Enumerator] this adapter with a block, otherwise an enumerator
      # @yield [selector, stored] visits each remaining entry
      # @yieldparam selector [Object] key or sequence position
      # @yieldparam stored [Core::Slot] encoded child value
      # @yieldreturn [void] ignored
      def each_from_index(index, &block)
        return enum_for(:each_from_index, index) unless block

        index += size if index.negative?
        return self unless index >= 0 && index < size

        each_normalized_index(index, &block)
        self
      end

      # Visits entries after the caller normalizes and validates the ordinal start.
      #
      # @param index [Integer] nonnegative valid sequence or sorted-entry position
      # @return [self] this adapter
      # @yield [selector, stored] visits each remaining entry
      # @yieldparam selector [Object] decoded sorted key or integer sequence position
      # @yieldparam stored [Core::Slot] encoded child value
      # @yieldreturn [void] ignored
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

      # Visits every entry in the order defined by the collection layout.
      #
      # @return [self, Enumerator] this adapter with a block, otherwise an enumerator
      # @yield [selector, stored] visits one entry
      # @yieldparam selector [Object] decoded key or integer sequence position
      # @yieldparam stored [Core::Slot] encoded child value
      # @yieldreturn [void] ignored
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

      # Finds the number of sorted keys strictly less than the requested key.
      #
      # @param selector [Object] key in the sorted collection's accepted key type
      # @return [Integer] zero-based position, including the insertion position for an absent key
      def rank(selector)
        sorted_collection.rank(key_bytes(selector))
      end

      # Visits sorted entries starting at the first key greater than or equal to the requested key.
      #
      # @param selector [Object] lower-bound sorted key
      # @return [self, Enumerator] this adapter with a block, otherwise an enumerator
      # @yield [key, stored] visits an entry in ascending key order
      # @yieldparam key [Object] decoded key
      # @yieldparam stored [Core::Slot] encoded child value
      # @yieldreturn [void] ignored
      def each_from(selector)
        return enum_for(:each_from, selector) unless block_given?

        sorted_collection.each_from(key_bytes(selector)) do |bytes, stored|
          key, value = sorted_entry(bytes, stored)
          yield key, value
        end
        self
      end

      # Returns the stable identity used to track a logical view location.
      #
      # @param selector [Object] key, member, or sequence position
      # @return [Integer, String] sequence position or canonical key bytes
      def selector_identity(selector)
        %i[array linked_array].include?(kind) ? selector : key_bytes(selector)
      end

      protected

      # Underlying sorted or sequence storage; maps and sets use separate indexes.
      #
      # @return [Core::SortedMap, Core::ArrayList, Core::LinkedArrayList, nil]
      #   underlying sorted or sequence storage, or nil for a map or set
      attr_reader :collection

      # Checks the active layout before using its collection-specific operations.
      #
      # @return [Core::LinkedArrayList] typed underlying collection
      # @raise [InvalidValueError] if the active layout has the wrong collection type
      def linked_collection
        collection = @collection
        invalid! unless collection.is_a?(Core::LinkedArrayList)

        collection
      end

      private

      # Requires an Integer selector before passing an index to core storage.
      #
      # @param selector [Object] candidate sequence position
      # @return [Integer] supplied index
      # @raise [TypeError] if the selector is not an Integer
      def index_selector(selector)
        raise TypeError, "index must be an Integer" unless selector.is_a?(Integer)

        selector
      end

      # Requires a stored child where the collection structure promises one.
      #
      # @param slot [Core::Slot, nil] result of an internal child lookup
      # @return [Core::Slot] present child
      # @raise [InvalidValueError] if the promised child is absent
      def required_slot(slot)
        invalid! unless slot

        slot
      end

      # Fetches an envelope or record field that must exist.
      #
      # @param collection [Core::ArrayList] envelope or internal record
      # @param index [Integer] nonnegative field position
      # @return [Core::Slot] required field
      # @raise [InvalidValueError] if the field is absent
      def fetch_slot(collection, index)
        required_slot(collection.get(index))
      end

      # Requires the marked envelope before reading or publishing its fields.
      #
      # @return [Core::ArrayList] active envelope
      # @raise [InvalidValueError] if no envelope has been initialized
      def envelope
        value = @envelope
        invalid! unless value

        value
      end

      # Requires the key kind recorded for a typed sorted collection.
      #
      # @return [Symbol] declared sorted-key kind
      # @raise [InvalidValueError] if the key-kind field is absent
      def declared_key_kind
        value = @key_kind
        invalid! unless value

        value
      end

      # Checks the active layout before using its collection-specific operations.
      #
      # @return [Core::ArrayList] typed underlying collection
      # @raise [InvalidValueError] if the active layout has the wrong collection type
      def array_collection
        collection = @collection
        invalid! unless collection.is_a?(Core::ArrayList)

        collection
      end

      # Checks the active layout before using its collection-specific operations.
      #
      # @return [Core::SortedMap] typed underlying collection
      # @raise [InvalidValueError] if the active layout has the wrong collection type
      def sorted_collection
        collection = @collection
        invalid! unless collection.is_a?(Core::SortedMap)

        collection
      end

      # Checks the active layout before using its collection-specific operations.
      #
      # @return [Core::ArrayList, Core::LinkedArrayList] typed underlying collection
      # @raise [InvalidValueError] if the active layout has the wrong collection type
      def sequence_collection
        collection = @collection
        invalid! unless collection.is_a?(Core::ArrayList) || collection.is_a?(Core::LinkedArrayList)

        collection
      end

      # Checks whether the collection uses a separate insertion-order index.
      #
      # @return [Boolean] true for Ruby maps and sets
      def ordered?
        %i[map set].include?(kind)
      end

      # Checks whether keys use the declared typed sort order.
      #
      # @return [Boolean] true for sorted maps and sorted sets
      def sorted?
        %i[sorted_map sorted_set].include?(kind)
      end

      # Builds a native array for an envelope or internal record.
      #
      # @param fields [Array<Core::Slot>] already encoded fields
      # @return [Core::ArrayList] new native array containing the fields
      def array(fields)
        output = Core::ArrayList.new(@context.cursor(Core::Slot.new))
        fields.each { |field| output.append(field) }
        output
      end

      # Builds empty storage and its envelope, then replaces the root cursor.
      # Maps and sets also reset the next insertion identifier.
      #
      # @return [void]
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

      # Validates the marker and field count, then opens the corresponding child storage.
      #
      # @return [void]
      # @raise [InvalidValueError] if the marker, field count, or child layout is inconsistent
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

      # Copies changed child roots and counters into the envelope and replaces the root cursor.
      #
      # @return [self] this adapter
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

      # Encodes a selector and attaches its logical path to value errors.
      #
      # @param selector [Object] key or member to encode
      # @return [String] canonical binary key bytes
      # @raise [ValueError] if the key is unsupported for this collection
      def key_bytes(selector)
        sorted? ? OrderedKeys.dump(selector, kind: declared_key_kind) : @profile.key_bytes(selector)
      rescue ValueError => e
        raise e.class.new(e.message, path: @path + [selector]), cause: e
      end

      # Requires untagged byte storage before reading an index key or digest.
      #
      # @param slot [Core::Slot, nil] candidate stored byte descriptor
      # @return [String] stored binary bytes
      # @raise [InvalidValueError] if the slot is absent, has the wrong tag, or has a format label
      def raw_bytes(slot)
        invalid! unless slot && %i[bytes short_bytes].include?(slot.tag)
        value = @context.database.core.read_bytes(slot, bound: @context.read_bound)
        invalid! if value.format_tag
        value.bytes
      end

      # Decodes an original key and restricts it to supported key scalar types.
      #
      # @param slot [Core::Slot] original stored key
      # @return [nil, Boolean, String, Integer, Float, Time, Symbol, UInt] decoded key
      # @raise [InvalidValueError] if the decoded value cannot represent a stored key
      def decode_key(slot)
        value = Scalars.decode(slot, core: @context.database.core, bound: @context.read_bound)
        case value
        when String, Integer, Float, Time, Symbol, true, false, nil, UInt then value
        else invalid!
        end
      end

      # Looks up an insertion-ordered record and validates its key and order references.
      #
      # @param digest [String] SHA-256 digest of the canonical key bytes
      # @param expected_bytes [String, nil] requested key identity, when lookup supplied one
      # @return [Core::ArrayList, nil] validated three-field record, or nil when absent
      # @raise [InvalidValueError] if the record or either index is inconsistent
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

      # Validates a sorted entry against its original key and returns the logical child.
      #
      # @param bytes [String] ordering bytes from the sorted index
      # @param stored [Core::Slot] original key or map record
      # @return [Array(Object, Core::Slot)] decoded key and value slot, with a null value for set members
      # @raise [InvalidValueError] if the record shape or re-encoded ordering bytes disagree
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

      # Stores a sorted entry while retaining the first original key representation.
      #
      # @param selector [Object] typed sorted key
      # @param stored [Core::Slot] encoded value, ignored for sorted sets
      # @return [void]
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

      # Updates an ordered entry or allocates its insertion identifier and both index entries.
      # Replacing a value preserves its original key and insertion position.
      #
      # @param selector [Object] supported Ruby key
      # @param stored [Core::Slot] encoded value, ignored for sets
      # @return [void]
      # @raise [RangeError] if another insertion identifier cannot fit in unsigned 64-bit storage
      # @raise [InvalidValueError] if an existing record or its indexes are inconsistent
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

      # Removes an array element by shifting each following stored slot to the previous position.
      #
      # @param selector [Integer] nonnegative element index
      # @return [void]
      # @raise [IndexError] if the selector is not an Integer within the array
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

      # Reports the required envelope field count for the active logical kind.
      #
      # @return [Integer] four for insertion-ordered collections, three for sorted collections, or two for sequences
      def envelope_size
        return 4 if ordered?

        sorted? ? 3 : 2
      end

      # Requires the native sequence tag that matches the envelope marker.
      #
      # @return [void]
      # @raise [InvalidValueError] if the sequence field has the wrong native layout
      def read_sequence_envelope
        child = fetch_slot(envelope, 1)
        expected = kind == :array ? :array_list : :linked_array_list
        invalid! unless child.tag == expected
        klass = kind == :array ? Core::ArrayList : Core::LinkedArrayList
        @collection = klass.new(@context.cursor(child))
      end

      # Reads the declared key kind and opens its native sorted-map storage.
      #
      # @return [void]
      # @raise [InvalidValueError] if the key-kind identifier or child tag is invalid
      def read_sorted_envelope
        key = fetch_slot(envelope, 1)
        child = fetch_slot(envelope, 2)
        invalid! unless key.tag == :uint && (@key_kind = KEY_KINDS.key(key.value)) && child.tag == :sorted_map
        @collection = Core::SortedMap.new(@context.cursor(child))
      end

      # Opens lookup and insertion-order indexes and checks their entry counts.
      #
      # @return [void]
      # @raise [InvalidValueError] if tags, counts, or the next insertion identifier disagree
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

      # Validates an insertion-order index entry and resolves its logical key and value.
      #
      # @param id_bytes [String] eight-byte big-endian insertion identifier
      # @param hash_slot [Core::Slot] untagged bytes containing the key digest
      # @return [Array(Object, Core::Slot)] decoded key and encoded value
      # @raise [InvalidValueError] if the identifier, digest, or referenced record is inconsistent
      def ordered_entry(id_bytes, hash_slot)
        invalid! unless id_bytes.bytesize == 8
        digest = raw_bytes(hash_slot)
        invalid! unless digest.bytesize == 32
        record = record_for(digest)
        invalid! unless record && fetch_slot(record, 2).value == id_bytes.unpack1("Q>")
        [decode_key(fetch_slot(record, 0)), fetch_slot(record, 1)]
      end

      # Checks agreement between a record, its canonical key bytes, and both indexes.
      #
      # @param record [Core::ArrayList] three-field ordered record
      # @param digest [String] lookup digest
      # @param id [Core::Slot] validated insertion-identifier field
      # @param expected_bytes [String, nil] requested canonical identity, when supplied
      # @return [void]
      # @raise [InvalidValueError] if key bytes, hashes, order references, or set values disagree
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

      # Reports an invalid Ruby collection envelope or inconsistent index record.
      #
      # @return [void]
      # @raise [InvalidValueError] always
      def invalid!
        raise InvalidValueError, "invalid Ruby container envelope or index record"
      end
    end
  end
end
