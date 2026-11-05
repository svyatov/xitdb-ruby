# frozen_string_literal: true

require "test_helper"

class FormatTest < Minitest::Test
  def test_header_and_null_vectors
    header = XitDB::Core::Header.new(file_id: 1, hash_id: "sha1", hash_size: 20)

    assert_equal "7869740000010014736861310000000000000001", header.to_bytes.unpack1("H*")
    assert_equal "800000000000000000", XitDB::Core::Slot.new(tag: :none, value: 0, full: true).to_bytes.unpack1("H*")
  end

  def test_crc64_xz_vectors
    assert_equal 0, XitDB::Core::CRC64.call("")
    assert_equal 0x330284772e652b05, XitDB::Core::CRC64.call("a")
    assert_equal 0x995dc9bbdf1939fa, XitDB::Core::CRC64.call("123456789")
  end

  def test_header_parses_without_losing_reserved_bytes_or_unknown_hash_ids
    bytes = ["786974ff00010000800000ff0123456789abcdef"].pack("H*")
    header = XitDB::Core::Header.parse(bytes)

    assert_equal 0x0123456789abcdef, header.file_id
    assert_equal "\x80\x00\x00\xff".b, header.hash_id
    assert_equal 0, header.hash_size
    assert_equal bytes, header.to_bytes
    bytes.clear

    assert_equal "\x80\x00\x00\xff".b, header.hash_id
    assert_predicate header.hash_id, :frozen?
  end

  def test_malformed_header_width_and_magic_are_corrupt
    ["", "xit", "x" * 19, "x" * 21, "bad\0\0\1\0\24sha1#{"\0" * 8}"].each do |bytes|
      assert_raises(XitDB::CorruptionError) { XitDB::Core::Header.parse(bytes) }
    end
  end

  def test_unsupported_header_version_has_a_distinct_error
    bytes = ["7869740000020014736861310000000000000001"].pack("H*")
    assert_raises(XitDB::FormatVersionError) { XitDB::Core::Header.parse(bytes) }
  end

  def test_header_fields_reject_overflow_and_wrong_types
    [-1, 2**64].each do |id|
      assert_raises(RangeError) { XitDB::Core::Header.new(file_id: id, hash_id: "sha1", hash_size: 20) }
    end
    [-1, 65_536].each do |size|
      assert_raises(RangeError) { XitDB::Core::Header.new(file_id: 1, hash_id: "sha1", hash_size: size) }
    end
    assert_raises(TypeError) { XitDB::Core::Header.new(file_id: 1.0, hash_id: "sha1", hash_size: 20) }
    assert_raises(TypeError) { XitDB::Core::Header.new(file_id: 1, hash_id: :sha1, hash_size: 20) }
    assert_raises(ArgumentError) { XitDB::Core::Header.new(file_id: 1, hash_id: "sha256", hash_size: 32) }
  end

  def test_null_is_occupied_and_zero_slot_is_empty
    null = XitDB::Core::Slot.null

    refute_predicate null, :empty?
    assert_equal "800000000000000000", null.to_bytes.unpack1("H*")
    empty = XitDB::Core::Slot.parse("\0" * 9)

    assert_predicate empty, :empty?
    assert_equal :none, empty.tag
    assert_equal 0, empty.value
    assert_same false, empty.full
    refute_predicate XitDB::Core::Slot.uint(0), :empty?
  end

  def test_integer_vectors_keep_signedness_and_all_64_bits
    [
      [:int, -(2**63), "098000000000000000"],
      [:int, -1, "09ffffffffffffffff"],
      [:int, (2**63) - 1, "097fffffffffffffff"],
      [:uint, 0, "080000000000000000"],
      [:uint, (2**64) - 1, "08ffffffffffffffff"]
    ].each do |kind, value, hex|
      slot = XitDB::Core::Slot.public_send(kind, value)

      assert_equal hex, slot.to_bytes.unpack1("H*")
      parsed = XitDB::Core::Slot.parse([hex].pack("H*"))

      assert_equal kind, parsed.tag
      assert_equal value & 0xffffffffffffffff, parsed.value
    end
  end

  def test_integer_factories_reject_overflow_and_coercion
    [-(2**63) - 1, 2**63].each do |value|
      assert_raises(RangeError) { XitDB::Core::Slot.int(value) }
    end
    [-1, 2**64].each do |value|
      assert_raises(RangeError) { XitDB::Core::Slot.uint(value) }
    end
    assert_raises(TypeError) { XitDB::Core::Slot.int(1.5) }
    assert_raises(TypeError) { XitDB::Core::Slot.uint("1") }
  end

  def test_floats_preserve_ieee_values
    [[1.5, "0a3ff8000000000000"], [-0.0, "0a8000000000000000"],
     [Float::INFINITY, "0a7ff0000000000000"], [-Float::INFINITY, "0afff0000000000000"]].each do |value, hex|
      assert_equal hex, XitDB::Core::Slot.float(value).to_bytes.unpack1("H*")
    end
    nan = ["0a7ff8000000000042"].pack("H*")

    assert_equal nan, XitDB::Core::Slot.parse(nan).to_bytes
    assert_raises(TypeError) { XitDB::Core::Slot.float("1.5") }
  end

  def test_all_upstream_tags_and_unknown_tags_round_trip
    tags = %i[none index array_list linked_array_list hash_map kv_pair bytes short_bytes uint int float
              hash_set counted_hash_map counted_hash_set sorted_map sorted_set sorted_kv_pair]
    tags.each_with_index do |tag, code|
      bytes = [code | 0x80, 0x0123456789abcdef].pack("CQ>")
      slot = XitDB::Core::Slot.parse(bytes)

      assert_equal tag, slot.tag
      assert_same true, slot.full
      assert_equal bytes, slot.to_bytes
    end
    [17, 127].each do |code|
      bytes = [code | 0x80, 7].pack("CQ>")
      slot = XitDB::Core::Slot.parse(bytes)

      assert_equal code, slot.tag
      assert_equal bytes, slot.to_bytes
      refute_predicate slot, :empty?
    end
  end

  def test_slots_reject_invalid_widths_and_fields
    ["", "\0" * 8, "\0" * 10].each do |bytes|
      assert_raises(XitDB::CorruptionError) { XitDB::Core::Slot.parse(bytes) }
    end
    [-1, 128, :unknown].each do |tag|
      assert_raises(ArgumentError) { XitDB::Core::Slot.new(tag: tag, value: 0) }
    end
    [-1, 2**64].each do |value|
      assert_raises(RangeError) { XitDB::Core::Slot.new(tag: :bytes, value: value) }
    end
    assert_raises(TypeError) { XitDB::Core::Slot.new(tag: :none, value: 0, full: 1) }
  end

  def test_value_error_owns_an_immutable_path_and_keeps_the_cause
    path = [+"profile", +"status", 2]
    original = RuntimeError.new("codec failed")
    error = assert_raises(XitDB::UnsupportedValueError) do
      raise original
    rescue RuntimeError
      raise XitDB::UnsupportedValueError.new("unsupported value", path: path)
    end
    path[0].replace("changed")
    path << "extra"

    assert_equal ["profile", "status", 2], error.path
    assert_predicate error.path, :frozen?
    assert_predicate error.path.first, :frozen?
    assert_same original, error.cause
    assert_kind_of XitDB::Error, error
  end

  def test_commit_error_requires_a_known_outcome
    %i[not_committed committed unknown].each do |outcome|
      assert_equal outcome, XitDB::CommitError.new("I/O failed", outcome: outcome).outcome
    end
    assert_raises(ArgumentError) { XitDB::CommitError.new("I/O failed", outcome: :retry) }
  end

  def test_key_collision_error_has_an_owned_immutable_value_path
    assert XitDB.const_defined?(:KeyCollisionError, false), "KeyCollisionError must be available"
    path = [+"records", 1]
    error = XitDB::KeyCollisionError.new("distinct keys have the same bytes", path: path)

    assert_kind_of XitDB::ValueError, error
    path.first.replace("changed")
    path << "extra"

    assert_equal ["records", 1], error.path
    assert_predicate error.path, :frozen?
    assert_predicate error.path.first, :frozen?
  end
end
