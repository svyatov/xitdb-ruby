# frozen_string_literal: true

require_relative "../ruby"
require_relative "ruby_storage"
require_relative "ruby_keys"

module XitDB
  module Verification
    # Applies Ruby collection roles to the physically verified latest snapshot.
    class RubyCollections
      include RubyStorage
      include RubyKeys

      Packed = Ruby::PackedMap
      Pages = Ruby::Pages

      def initialize(scan, graph, values: nil)
        @scan = scan
        @graph = graph
        @values = values
      end

      def visit(slot, offset, role: :value, count: nil)
        if slot.tag == :record
          record(slot, role, count)
        elsif role == :page
          invalid!(:page, offset) unless Graph::BYTE_TAGS.include?(slot.tag) && !slot.full?
          values.page!(slot, count: count || invalid!(:page_count, offset), offset: offset, path: @graph.path)
        elsif slot.tag == :array_list
          envelope(slot, role)
        else
          invalid!(:root, offset) if role == :root
          invalid!(:scalar, offset) unless %i[none int uint float bytes short_bytes].include?(slot.tag)
          values.scalar!(slot, offset: offset, path: @graph.path)
        end
        nil
      end

      private

      def values
        @values || raise(ArgumentError, "Ruby value verifier required")
      end

      def child(slot, offset, selector, role: :value, count: nil)
        @graph.logical_child(slot, role, count, offset, selector) { visit(slot, offset, role: role, count: count) }
      end

      def record(slot, role, expected)
        pointer = slot.value
        metadata, count = Core::Format.pair(@scan.read(pointer, 8), "NN")
        validate_metadata!(metadata, role, pointer)
        start = pointer + 8
        case metadata
        when Packed::MAP, Packed::SET then literal(metadata, start, count)
        when Packed::SCHEMA_MAP then dictionary(start, count)
        when Ruby::PackedArray::INLINE then inline(start, count, expected)
        when Ruby::PackedArray::TREE
          invalid!(:record_arity, pointer + 4) unless count == 1
          sequence(expect!(slot_at(start), :array_list, start), expected)
        when Pages::ARRAY then page_array(start, count)
        when Pages::ROW then row(start, count)
        end
      end

      def validate_metadata!(metadata, role, pointer)
        invalid!(:record_metadata, pointer) unless (1..8).cover?(metadata) && metadata != Packed::DICTIONARY
        invalid!(:root, pointer) if role == :root && ![Packed::MAP, Packed::SCHEMA_MAP, Pages::ROW].include?(metadata)
        return unless role == :page && ![Ruby::PackedArray::INLINE, Ruby::PackedArray::TREE].include?(metadata)

        invalid!(:page, pointer)
      end

      def literal(metadata, start, count)
        stride = metadata == Packed::MAP ? 2 : 1
        invalid!(:record_arity, start - 4) unless (count % stride).zero? && count / stride <= Packed::MAX_MEMBERS
        packed(start, count / stride, stride, stride == 2 ? start + 9 : nil)
      end

      def inline(start, count, expected)
        invalid!(:record_arity, start - 4) if count > Ruby::PackedArray::MAX_FIELDS
        invalid!(:page_count, start - 4) if expected && count != expected
        count.times { |i| child(slot_at(start + (9 * i)), start + (9 * i), i.to_s) }
      end

      def dictionary(start, count)
        invalid!(:record_arity, start - 4) unless count.between?(3, 17)
        pointer = expect!(slot_at(start), :record, start).value
        metadata, width = Core::Format.pair(@scan.read(pointer, 8), "NN")
        invalid!(:dictionary, pointer) unless metadata == Packed::DICTIONARY
        invalid!(:dictionary_width, pointer + 4) unless width == count - 1
        packed(pointer + 8, width, 1, start + 9)
      end

      def packed(start, count, stride, values_start)
        # @type var seen: Hash[String, bool]
        seen = {}
        count.times do |i|
          key = start + (9 * stride * i)
          selector = with_key(slot_at(key), key, packed: true) do |identity, name|
            invalid!(:duplicate_key, key) if seen.key?(identity)
            seen[identity] = true
            name
          end
          next unless values_start

          position = values_start + (9 * stride * i)
          child(slot_at(position), position, selector)
        end
      end

      def page_array(start, count)
        invalid!(:record_arity, start - 4) unless count == 2
        rows = expect!(slot_at(start), :uint, start).value
        pages = expect!(slot_at(start + 9), :array_list, start + 9)
        size = uint(pages.value)
        invalid!(:page_count, start) unless rows.positive? && size == rows.ceildiv(Pages::ROW_LIMIT)
        size.times do |index|
          page, offset, = array_entry(pages, size, index)
          length = [Pages::ROW_LIMIT, rows - (index * Pages::ROW_LIMIT)].min
          child(page, offset, "page[#{index}]", role: :page, count: length)
        end
      end

      def row(start, count)
        invalid!(:record_arity, start - 4) unless count == 3
        page = slot_at(start)
        invalid!(:page, start) unless Graph::BYTE_TAGS.include?(page.tag) && !page.full?
        index = expect!(slot_at(start + 9), :uint, start + 9).value
        rows = expect!(slot_at(start + 18), :uint, start + 18).value
        invalid!(:page_count, start + 18) unless rows.between?(1, Pages::ROW_LIMIT) && index < rows
        child(page, start, "row[#{index}]", role: :page, count: rows)
      end

      def sequence(slot, expected = nil)
        size = uint(slot.value)
        invalid!(:page_count, slot.value) if expected && expected != size
        index = 0
        while index < size
          if slot.tag == :array_list
            item, offset, following = array_entry(slot, size, index)
          else
            item, offset = tree_entry(slot, index)
            following = index + 1
          end
          child(item, offset, index.to_s)
          index = following
        end
      end

      def envelope(slot, role)
        size = uint(slot.value)
        invalid!(:record_arity, slot.value) unless size.between?(2, 4)
        fields = fixed_fields(slot, size)
        kind = envelope_kind!(fields.fetch(0), role)
        case kind
        when :array, :linked_array
          invalid!(:record_arity, slot.value) unless size == 2
          sequence(field_slot!(fields.fetch(1), kind == :array ? :array_list : :linked_array_list))
        when :map, :set
          invalid!(:record_arity, slot.value) unless size == 4
          indexed(fields, kind)
        else
          invalid!(:record_arity, slot.value) unless size == 3
          sorted(fields, kind)
        end
      end

      def envelope_kind!(marker, role)
        kind = Ruby::Containers::MARKERS.key(field_slot!(marker, :uint).value)
        invalid!(:record_metadata, marker.offset) unless kind
        invalid!(:root, marker.offset) if role == :root && !%i[map sorted_map].include?(kind)
        kind
      end

      def indexed(fields, kind)
        counter = fields.fetch(1)
        maximum = field_slot!(counter, :uint).value
        lookup = field_slot!(fields.fetch(2), :counted_hash_map)
        order = field_slot!(fields.fetch(3), :sorted_map)
        size = uint(order.value)
        invalid!(:index_membership, order.value) unless size == uint(lookup.value)
        invalid!(:index_membership, counter.offset) if size > maximum
        # Sorted order keys are unique. Requiring each to resolve to a lookup
        # record with that same ID proves a bijection when both counts agree.
        size.times do |rank|
          id_key, hash_field = sorted_pair(order, rank)
          id = Core::Format.unsigned(raw_bytes!(id_key.slot, 8, id_key.offset))
          invalid!(:order_id, id_key.offset) unless id < maximum
          digest = raw_bytes!(hash_field.slot, 32, hash_field.offset)
          key, record = lookup_pair!(lookup, digest, hash_field.offset)
          entry = fields!(record.slot, 3, record.offset)
          stored_id = entry.fetch(2)
          invalid!(:index_membership, stored_id.offset) unless field_slot!(stored_id, :uint).value == id
          original = entry.fetch(0)
          selector = with_key(original.slot, original.offset) do |identity, name|
            invalid!(:key_identity, key.offset) unless raw_bytes!(key.slot, identity.bytesize, key.offset) == identity
            invalid!(:key_digest, key.offset - 32) unless Digest::SHA256.digest(identity) == digest
            name
          end
          value = entry.fetch(1)
          invalid!(:set_value, value.offset) if kind == :set && value.slot != Core::Slot.null
          child(value.slot, value.offset, selector)
        end
      end

      def sorted(fields, kind)
        declaration = fields.fetch(1)
        key_kind = Ruby::Containers::KEY_KINDS.key(field_slot!(declaration, :uint).value)
        invalid!(:key_kind, declaration.offset) unless key_kind
        tree = field_slot!(fields.fetch(2), :sorted_map)
        uint(tree.value).times do |rank|
          key, stored = sorted_pair(tree, rank)
          pair = fields!(stored.slot, 2, stored.offset) if kind == :sorted_map
          original = pair ? pair.fetch(0) : stored
          selector = with_key(original.slot, original.offset, kind: key_kind) do |identity, name|
            invalid!(:key_identity, key.offset) unless raw_bytes!(key.slot, identity.bytesize, key.offset) == identity
            name
          end
          value = pair.fetch(1) if pair
          child(value.slot, value.offset, selector) if value
        end
      end
    end
  end
end
