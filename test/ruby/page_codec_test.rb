# frozen_string_literal: true

require_relative "test_helper"
require "xitdb/ruby"
require "open3"
require "rbconfig"
require "bundler"

# Exercises the bounded native page format independently of storage adapters.
class PageCodecTest < Minitest::Test
  def setup
    @codec = XitDB::Ruby::PageCodec
  end

  def test_exact_cells_and_selected_rows
    values = [nil, false, true, 0, -1, (2**62) - 1, -(2**62), 0.0, -0.0,
              Float::INFINITY, -Float::INFINITY, ["7ff800000000002a"].pack("H*").unpack1("G")]
    rows = values.map { |value| { "key" => value } }
    bytes = @codec.encode_page(rows)

    assert_equal "XP01", bytes.byteslice(0, 4)
    assert_equal Encoding::BINARY, bytes.encoding
    decoded = @codec.decode_page(bytes, rows.size)
    rows.each_with_index do |row, index|
      assert_exact_row row, decoded.fetch(index)
      assert_exact_row row, @codec.decode_row(bytes, index, rows.size)
    end
    assert_equal rows.size, decoded.size
  end

  def test_all_registered_string_encodings_and_invalid_bytes
    Encoding.list.each do |encoding|
      text = "\x00\x7f\x80\xff".b.force_encoding(encoding)
      rows = [{ "key" => text }, { "key" => text.dup }]
      decoded = @codec.decode_page(@codec.encode_page(rows))

      assert_equal encoding, decoded[0]["key"].encoding
      assert_equal text.b, decoded[0]["key"].b
      decoded[0]["key"].clear

      assert_equal text.b, decoded[1]["key"].b
      assert_equal 4, text.bytesize
    end
  end

  def test_schema_preserves_original_encoding_and_order
    keys = ["a".b, "b".encode("US-ASCII"), "\xff".b, "c".encode("UTF-16LE")]
    row = keys.to_h { |key| [key, 1] }
    decoded = @codec.decode_row(@codec.encode_page([row]), 0)

    assert_equal keys.map(&:b), decoded.keys.map(&:b)
    assert_equal keys.map(&:encoding), decoded.keys.map(&:encoding)
    assert decoded.keys.all?(&:frozen?)
    assert_equal row, decoded
  end

  def test_row_field_and_byte_limits
    assert_equal Array.new(1024) { {} }, @codec.decode_page(@codec.encode_page(Array.new(1024) { {} }))
    row = 16.times.to_h { |index| [index.to_s, nil] }

    assert_equal [row], @codec.decode_page(@codec.encode_page([row]))
    text = "x".b * 65_523
    bytes = @codec.encode_page([{ "a" => text }])

    assert_equal 65_536, bytes.bytesize
    assert_equal text, @codec.decode_row(bytes, 0)["a"]
    assert_nil @codec.encode_page([{ "a" => "#{text}x" }])
    assert_nil @codec.encode_page(Array.new(1025) { {} })
    assert_nil @codec.encode_page([row.merge("extra" => nil)])
  end

  def test_unsupported_inputs_request_general_storage
    values = [nil, {}, [], [nil], [{ 1 => nil }], [{ "a" => [] }], [{ "a" => {} }],
              [{ "a" => :symbol }], [{ "a" => 2**100 }], [{ "a" => Object.new }],
              [{ "a" => 1 }, { "b" => 2 }], [{ "a" => 1 }, {}],
              [{ "a" => 1, "b" => 2 }, { "b" => 2, "a" => 1 }],
              [{ "a" => 1 }, { "a".b => 2 }], [Hash.new(false)], [Hash.new { 1 }],
              [{}.compare_by_identity], Class.new(Array).new([{}]), [Class.new(Hash).new],
              [{ "a" => Class.new(String).new("value") }]]

    values.each { |value| assert_nil @codec.encode_page(value), value.inspect }
    object = BasicObject.new

    assert_nil @codec.encode_page(object)
    assert_nil @codec.encode_page([{ "a" => object }])
  end

  def test_singleton_hooks_are_not_invoked
    [[], {}, +"key", +"value"].each do |value|
      def value.class = raise("untrusted class hook")
      def value.is_a?(*) = raise("untrusted type hook")
      def value.default = raise("untrusted default hook")
      def value.to_str = raise("untrusted string hook")

      assert_nil @codec.encode_page(value)
      assert_nil @codec.encode_page([value])
      assert_nil @codec.encode_page([{ "key" => value }])
    end
  end

  def test_malformed_headers_and_counts
    valid = @codec.encode_page([{ "a" => nil }])
    invalid = ["", "XP0", "XP02\x01\x00", "XP01\x00\x00", "XP01\x81\x08\x00",
               "XP01\x01\x11", "XP01\x81\x00\x00", "XP01\x80#{"\xff" * 10}",
               "#{valid}\x00", "x" * 65_537]

    invalid.each { |bytes| assert_invalid bytes.b }
    valid.bytesize.times { |length| assert_invalid valid.byteslice(0, length) }
    assert_raises(XitDB::InvalidValueError) { @codec.decode_page(valid, 2) }
    assert_raises(XitDB::InvalidValueError) { @codec.decode_row(valid, 0, 2) }
  end

  def test_malformed_cells_and_schema
    # One row, one UTF-8 key named a, followed by a deliberately invalid cell.
    prefix = "XP01\x01\x01\x05\x01a".b

    ["\xff", "\x03\x80\x00", "\x03#{"\xff" * 9}\x02", "\x04\x00",
     "\x05\x02a", "\x08\x00\x00", "\x08\x03bad\x00", "\x08\x03a\x00b\x00",
     "\x08\x05UTF-8\x00", "\x08\x80\x01", "\x08\x06binary\x00"].each do |cell|
      assert_invalid prefix + cell.b
    end
    assert_invalid "XP01\x01\x01\x00\x00".b
    assert_invalid "XP01\x01\x02\x05\x01a\x05\x01a\x00\x00".b
    assert_invalid "XP01\x01\x02\x05\x01a\x07\x01a\x00\x00".b
    assert_invalid "XP01\x01\x02\x05\x00\x08\x08UTF-16LE\x00\x00\x00".b
  end

  def test_selected_row_still_validates_other_rows
    bytes = @codec.encode_page([{ "a" => nil }, { "a" => nil }])
    bytes.setbyte(bytes.bytesize - 1, 255)
    assert_raises(XitDB::InvalidValueError) { @codec.decode_row(bytes, 0) }
    bytes = @codec.encode_page([{ "a" => "safe" }, { "a" => "also safe" }])
    bytes.setbyte(bytes.bytesize - 10, 255)
    assert_raises(XitDB::InvalidValueError) { @codec.decode_row(bytes, 0) }
  end

  def test_decode_argument_types_and_row_positions
    bytes = @codec.encode_page([{}])
    assert_raises(TypeError) { @codec.decode_page([]) }
    assert_raises(TypeError) { @codec.decode_row(bytes, "0") }
    assert_raises(TypeError) { @codec.decode_page(bytes, "1") }
    [-1, 1, 2**100].each { |index| assert_raises(IndexError) { @codec.decode_row(bytes, index) } }
    [0, -1, 1025, 2**100].each do |count|
      assert_raises(XitDB::InvalidValueError) { @codec.decode_page(bytes, count) }
    end
  end

  def test_direct_checkout_entry_point_loads_its_compiled_extension
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e(
        { "RUBYOPT" => nil, "RUBYLIB" => nil }, RbConfig.ruby, "-e",
        'require_relative "lib/xitdb/ruby"; puts XitDB::Ruby::PageCodec.decode_page("XP01\\x01\\x00")',
        chdir: File.expand_path("../..", __dir__)
      )
    end

    assert_predicate status, :success?, output
    assert_equal "{}\n", output
  end

  private

  def assert_invalid(bytes)
    assert_raises(XitDB::InvalidValueError) { @codec.decode_page(bytes) }
    assert_raises(XitDB::InvalidValueError) { @codec.decode_row(bytes, 0) }
  end

  def assert_exact_row(expected, actual)
    assert_equal expected.keys, actual.keys
    value = expected.fetch("key")
    result = actual.fetch("key")

    assert_equal value.class, result.class
    if value.is_a?(Float)
      assert_equal [value].pack("G"), [result].pack("G")
    else
      assert_equal Marshal.dump(value), Marshal.dump(result)
    end
  end
end
