# frozen_string_literal: true

require_relative "test_helper"
require "xitdb/ruby"
require "xitdb/verification/graph"
require "tmpdir"

class VerificationCollectionsTest < Minitest::Test
  Core = XitDB::Core
  Slot = Core::Slot
  Packed = XitDB::Ruby::PackedMap
  Pages = XitDB::Ruby::Pages

  def scalar!(_slot, offset:, path:); end

  def page!(_slot, count:, offset:, path:)
    assert_kind_of Integer, offset
    assert_kind_of String, path
    @pages << count
  end

  def verify(limits: {}, &build)
    @pages = []
    Dir.mktmpdir do |directory|
      path = File.join(directory, "ruby.xit")
      core = Core::Database.open(path, hash_id: "rb05", hash_size: 32)
      begin
        @core = core
        core.transaction do |cursor|
          @tx = cursor.transaction
          cursor.replace(list(yield))
        end
      ensure
        core.close
      end
      XitDB::Verification::Scan.open(path, limits: limits) do |scan|
        XitDB::Verification::Graph.new(scan).verify!(scan.root, role: :ruby_root, values: self)
      end
    end
  end

  def record(meta, *fields)
    Core::Record.append(@tx, metadata: meta, fields: fields)
  end

  def list(*fields)
    Core::ArrayList.new(@tx.cursor(slot: Slot.new), fields: fields).cursor.slot
  end

  def indexed(key: "item", ordered_digest: nil, order_id: 0)
    bytes = XitDB::Ruby::KeyEncoding.dump(key)
    digest = Digest::SHA256.digest(bytes)
    lookup = Core::HashMap.new(@tx.cursor(slot: Slot.new), counted: true)
    lookup.put(digest, key: @core.bytes(bytes), value: list(@core.bytes(key), Slot.null, Slot.uint(0)))
    order = Core::SortedMap.new(@tx.cursor(slot: Slot.new))
    order.put([order_id].pack("Q>"), value: @core.bytes(ordered_digest || digest))
    list(Slot.uint(XitDB::Ruby::Containers::MARKERS.fetch(:map)), Slot.uint(1), lookup.cursor.slot, order.cursor.slot)
  end

  def test_literal_schema_and_paged_maps
    assert_nil(verify do
      dictionary = record(Packed::DICTIONARY, Slot.int(1), Slot.int(2))
      pages = record(Pages::ARRAY, Slot.uint(1025), list(@core.bytes("a"), @core.bytes("b")))
      record(Packed::SCHEMA_MAP, dictionary, pages, record(Packed::MAP, Slot.int(1), Slot.null))
    end)
    assert_equal [1024, 1], @pages
  end

  def test_record_metadata_arity_and_root_kind
    [[91, [], :record_metadata], [Packed::MAP, [Slot.int(1)], :record_arity],
     [Packed::SET, [], :root]].each do |meta, fields, check|
      error = assert_raises(XitDB::VerificationError) { verify { record(meta, *fields) } }
      assert_equal check, error.check
    end
  end

  [XitDB::Ruby::PackedArray::TREE, Packed::SCHEMA_MAP, Pages::ARRAY, Pages::ROW].each do |metadata|
    define_method("test_record_#{metadata}_reports_the_invalid_count_field") do
      count_offset = nil
      error = assert_raises(XitDB::VerificationError) do
        verify do
          value = record(metadata)
          count_offset = value.value + 4
          record(Packed::MAP, Slot.int(1), value)
        end
      end
      assert_equal [:record_arity, count_offset], [error.check, error.offset]
    end
  end

  def test_envelope_reports_the_invalid_field_offset
    markers = XitDB::Ruby::Containers::MARKERS
    [[:sorted_map, 1, :key_kind], [:sorted_map, 2, :layout], [:map, 1, :layout],
     [:map, 2, :layout], [:map, 3, :layout], [:linked_array, 1, :layout]].each do |kind, index, check|
      error = assert_raises(XitDB::VerificationError) do
        verify do
          lookup = Core::HashMap.new(@tx.cursor(slot: Slot.new), counted: true)
          sorted = Core::SortedMap.new(@tx.cursor(slot: Slot.new))
          fields = case kind
                   when :sorted_map then [Slot.uint(markers.fetch(kind)), Slot.uint(1), sorted.cursor.slot]
                   when :map then [Slot.uint(markers.fetch(kind)), Slot.uint(0), lookup.cursor.slot, sorted.cursor.slot]
                   else [Slot.uint(markers.fetch(kind)), Slot.null]
                   end
          fields[index] = check == :key_kind ? Slot.uint(99) : Slot.null
          envelope = list(*fields)
          @expected_offset = Core::Format.unsigned(@tx.read_at(envelope.value + 8, 8)) + (index * Slot::SIZE)
          record(Packed::MAP, Slot.int(0), envelope)
        end
      end
      assert_equal check, error.check
      assert_equal @expected_offset, error.offset, "#{kind} field #{index}"
    end
  end

  def test_entry_reports_the_original_key_field_offset
    order_key = [0].pack("Q>")
    %i[sorted_map map].each do |kind|
      error = assert_raises(XitDB::VerificationError) do
        verify do
          marker = Slot.uint(XitDB::Ruby::Containers::MARKERS.fetch(kind))
          sorted = Core::SortedMap.new(@tx.cursor(slot: Slot.new))
          invalid_key = list
          entry = kind == :map ? list(invalid_key, Slot.null, Slot.uint(0)) : list(invalid_key, Slot.null)
          @expected_offset = Core::Format.unsigned(@tx.read_at(entry.value + 8, 8))
          if kind == :sorted_map
            sorted.put("s", value: entry)
            list(marker, Slot.uint(1), sorted.cursor.slot)
          else
            identity = XitDB::Ruby::KeyEncoding.dump("s")
            digest = Digest::SHA256.digest(identity)
            lookup = Core::HashMap.new(@tx.cursor(slot: Slot.new), counted: true)
            lookup.put(digest, key: @core.bytes(identity), value: entry)
            sorted.put(order_key, value: @core.bytes(digest))
            list(marker, Slot.uint(1), lookup.cursor.slot, sorted.cursor.slot)
          end
        end
      end
      assert_equal :key_identity, error.check
      assert_equal @expected_offset, error.offset
    end
  end

  def test_duplicate_canonical_keys
    error = assert_raises(XitDB::VerificationError) do
      verify { record(Packed::MAP, Slot.float(-0.0), Slot.null, Slot.float(0.0), Slot.null) }
    end
    assert_equal :duplicate_key, error.check
  end

  def test_dictionary_width
    error = assert_raises(XitDB::VerificationError) do
      verify do
        dictionary = record(Packed::DICTIONARY, Slot.int(1), Slot.int(2), Slot.int(3))
        record(Packed::SCHEMA_MAP, dictionary, Slot.null, Slot.null)
      end
    end
    assert_equal :dictionary_width, error.check
  end

  def test_lookup_and_order_disagree
    error = assert_raises(XitDB::VerificationError) do
      verify { indexed(ordered_digest: Digest::SHA256.digest("other")) }
    end
    assert_equal :index_membership, error.check
  end

  def test_order_identifier_out_of_range
    error = assert_raises(XitDB::VerificationError) { verify { indexed(order_id: 1) } }
    assert_equal :order_id, error.check
  end

  def test_indexed_key_uses_scalar_budget_before_materializing
    assert_nil(verify { indexed })
    error = assert_raises(XitDB::VerificationLimitError) do
      verify(limits: { scalar_bytes: 256 }) { indexed(key: "x" * 4096) }
    end
    assert_equal :scalar_bytes, error.limit
  end

  def test_sorted_key_agrees_with_original
    error = assert_raises(XitDB::VerificationError) do
      verify do
        sorted = Core::SortedMap.new(@tx.cursor(slot: Slot.new))
        sorted.put("a", value: list(@core.bytes("b"), Slot.null))
        list(Slot.uint(XitDB::Ruby::Containers::MARKERS.fetch(:sorted_map)), Slot.uint(1), sorted.cursor.slot)
      end
    end
    assert_equal :key_identity, error.check
  end

  def test_public_writer_layouts_and_all_sorted_key_kinds
    Dir.mktmpdir do |directory|
      path = File.join(directory, "collections.xit")
      XitDB::Ruby.open(path) do |db|
        db.transaction do |root|
          root[:items] = (0...40).to_a
          root[:members] = Set.new(0...40)
          root[:linked] = XitDB.linked_array
          40.times { |i| root[:linked] << i }
          { integer: -(2**128), time: Time.at(Rational(1, 3)), string: "é", float: -0.25 }.each do |kind, key|
            root[kind] = XitDB.sorted_set(key: kind)
            root[kind].add(key)
          end
        end
      end

      XitDB::Verification::Scan.open(path) do |scan|
        assert_nil XitDB::Verification::Graph.new(scan).verify!(scan.root, role: :ruby_root, values: self)
      end
    end
  end

  def test_sorted_pair_with_a_stored_digest
    error = assert_raises(XitDB::VerificationError) do
      verify do
        sorted = Core::SortedMap.new(@tx.cursor(slot: Slot.new))
        original = @core.bytes("key")
        sorted.put("key", value: original)
        leaf = Core::Format.unsigned(@tx.read_at(sorted.cursor.slot.value + 8, 8))
        pair = @tx.append(Digest::SHA256.digest("other") + original.to_bytes + original.to_bytes)
        @tx.write_at(leaf + 2, Slot.new(tag: :kv_pair, value: pair).to_bytes)
        marker = XitDB::Ruby::Containers::MARKERS.fetch(:sorted_set)
        record(Packed::MAP, Slot.int(1), list(Slot.uint(marker), Slot.uint(1), sorted.cursor.slot))
      end
    end
    assert_equal :key_digest, error.check
  end

  def test_page_count_applies_to_each_reference
    error = assert_raises(XitDB::VerificationError) do
      verify do
        shared = record(XitDB::Ruby::PackedArray::INLINE, Slot.null)
        first = record(Pages::ARRAY, Slot.uint(1), list(shared))
        second = record(Pages::ARRAY, Slot.uint(2), list(shared))
        record(Packed::MAP, Slot.int(1), first, Slot.int(2), second)
      end
    end
    assert_equal :page_count, error.check
    assert_equal "$/2/page[0]", error.path
  end

  def test_row_reference_carries_the_declared_count
    assert_nil(verify { record(Pages::ROW, @core.bytes("page"), Slot.uint(1), Slot.uint(3)) })
    assert_equal [3], @pages
    error = assert_raises(XitDB::VerificationError) do
      verify { record(Pages::ROW, @core.bytes("page"), Slot.uint(3), Slot.uint(3)) }
    end
    assert_equal :page_count, error.check
  end

  def test_builtin_key_types_and_unsupported_key_slots
    assert_nil(verify do
      keys = [nil, false, true, 2**80, "text", :field, 1.5]
      fields = keys.flat_map { |key| [XitDB::Ruby::Scalars.encode(key, core: @core), Slot.null] }
      record(Packed::MAP, *fields, Slot.uint(12), Slot.null)
    end)
    error = assert_raises(XitDB::VerificationError) do
      verify { record(Packed::MAP, @core.bytes("data", format_tag: "zz"), Slot.null) }
    end
    assert_equal :key_identity, error.check
    error = assert_raises(XitDB::VerificationError) do
      verify { record(Packed::MAP, list, Slot.null) }
    end
    assert_equal :key_identity, error.check
  end
end
