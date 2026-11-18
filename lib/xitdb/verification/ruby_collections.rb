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
          invalid!(:record_arity, pointer) unless count == 1
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
        invalid!(:record_arity, start) unless count.between?(3, 17)
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
        invalid!(:record_arity, start) unless count == 2
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
        invalid!(:record_arity, start) unless count == 3
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
        marker, offset, = array_entry(slot, size, 0)
        kind = Ruby::Containers::MARKERS.key(expect!(marker, :uint, offset).value)
        invalid!(:record_metadata, offset) unless kind
        invalid!(:root, offset) if role == :root && !%i[map sorted_map].include?(kind)
        case kind
        when :array, :linked_array
          seq = fields!(slot, 2, offset).fetch(1)
          sequence(expect!(seq, kind == :array ? :array_list : :linked_array_list, offset))
        when :map, :set then indexed(slot, kind, offset)
        else sorted(slot, kind, offset)
        end
      end

      def indexed(slot, kind, offset)
        fields = fields!(slot, 4, offset)
        maximum = expect!(fields.fetch(1), :uint, offset).value
        lookup = expect!(fields.fetch(2), :counted_hash_map, offset)
        order = expect!(fields.fetch(3), :sorted_map, offset)
        size = uint(order.value)
        invalid!(:index_membership, offset) unless size == uint(lookup.value) && size <= maximum
        # Sorted order keys are unique. Requiring each to resolve to a lookup
        # record with that same ID proves a bijection when both counts agree.
        size.times do |rank|
          id_key, digest_slot, position = sorted_pair(order, rank)
          id = Core::Format.unsigned(raw_bytes!(id_key, 8, position))
          invalid!(:order_id, position) unless id < maximum
          digest = raw_bytes!(digest_slot, 32, position)
          key, record, source = lookup_pair!(lookup, digest, position)
          entry = fields!(record, 3, source)
          invalid!(:index_membership, source) unless expect!(entry.fetch(2), :uint, source).value == id
          selector = with_key(entry.fetch(0), source) do |identity, name|
            invalid!(:key_identity, source) unless raw_bytes!(key, identity.bytesize, source) == identity
            invalid!(:key_digest, source) unless Digest::SHA256.digest(identity) == digest
            name
          end
          value = entry.fetch(1)
          invalid!(:set_value, source) if kind == :set && value != Core::Slot.null
          child(value, array_entry(record, 3, 1)[1], selector)
        end
      end

      def sorted(slot, kind, offset)
        fields = fields!(slot, 3, offset)
        declaration = fields.fetch(1)
        key_kind = Ruby::Containers::KEY_KINDS.key(expect!(declaration, :uint, offset).value)
        invalid!(:key_kind, offset) unless key_kind
        tree = expect!(fields.fetch(2), :sorted_map, offset)
        uint(tree.value).times do |rank|
          key, stored, position = sorted_pair(tree, rank)
          pair = fields!(stored, 2, position) if kind == :sorted_map
          original = pair ? pair.fetch(0) : stored
          selector = with_key(original, position, kind: key_kind) do |identity, name|
            invalid!(:key_identity, position) unless raw_bytes!(key, identity.bytesize, position) == identity
            name
          end
          child(pair.fetch(1), array_entry(stored, 2, 1)[1], selector) if pair
        end
      end
    end
  end
end
