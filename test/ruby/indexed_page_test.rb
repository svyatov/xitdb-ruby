# frozen_string_literal: true

require_relative "test_helper"
require "xitdb/ruby"
require "digest"

# Verifies indexed compact pages, integrity, and profile compatibility.
class IndexedPageTest < Minitest::Test
  def setup
    @codec = XitDB::Ruby::PageCodec
  end

  def test_indexed_cells_preserve_values_and_boundaries
    negative_zero = [-0.0].pack("G")
    [1, 16, 32, 58, 1000, 1024].each do |count|
      rows = Array.new(count) { |index| { "integer" => index - 100, "float" => -0.0, "string" => "\xff".b } }
      bytes = @codec.encode_page(rows)

      assert_equal "XR01", bytes.byteslice(0, 4)
      assert_operator bytes.bytesize, :<=, 65_536
      assert_equal rows, @codec.decode_page(bytes, count)
      [0, count / 2, count - 1].uniq.each do |index|
        result = @codec.decode_row(bytes, index, count)

        assert_equal rows[index], result
        assert_equal negative_zero, [result.fetch("float")].pack("G")
        assert_equal Encoding::BINARY, result.fetch("string").encoding
      end
    end
  end

  def test_selected_read_visits_only_schema_and_requested_cells
    rows = Array.new(1000) { |index| { "a" => index, "b" => "text", "c" => false } }
    bytes = @codec.encode_page(rows)
    calls = 0
    trace = TracePoint.new(:call) do |event|
      calls += 1 if event.defined_class == XitDB::Ruby::PageDecoder && %i[cell skip_cell].include?(event.method_id)
    end
    result = trace.enable { @codec.decode_row(bytes, 999, 1000) }

    assert_equal rows[999], result
    assert_operator calls, :<=, 6
  ensure
    trace&.disable
  end

  def test_integrity_detects_valid_looking_changes_in_other_rows
    bytes = @codec.encode_page([{ "a" => 1 }, { "a" => 2 }])
    # Changing a payload bit can produce another valid scalar, so parsing alone is insufficient.
    bytes.bytesize.times do |position|
      damaged = bytes.dup
      damaged.setbyte(position, damaged.getbyte(position) ^ 1)

      assert_raises(XitDB::InvalidValueError) { @codec.decode_row(damaged, 0) }
    end
  end

  def test_rechecksummed_unaccessed_invalid_cells_are_deferred
    bytes = @codec.encode_page([{ "a" => nil }, { "a" => nil }])
    # Nine schema bytes, six offset bytes, then two nil cells.
    bytes.setbyte(16, 255)
    bytes = checksum(bytes)

    assert_equal({ "a" => nil }, @codec.decode_row(bytes, 0))
    assert_raises(XitDB::InvalidValueError) { @codec.decode_row(bytes, 1) }
    assert_raises(XitDB::InvalidValueError) { @codec.decode_page(bytes) }
  end

  def test_rechecksummed_offsets_reject_missing_and_overlapping_rows
    bytes = @codec.encode_page([{ "a" => nil }, { "a" => nil }])
    [0, 65_535].each do |offset|
      damaged = bytes.dup
      damaged[11, 2] = [offset].pack("S<")
      damaged = checksum(damaged)

      assert_raises(XitDB::InvalidValueError) { @codec.decode_row(damaged, 0) }
      assert_raises(XitDB::InvalidValueError) { @codec.decode_page(damaged) }
    end
  end

  def test_directory_and_integrity_overhead_falls_back_without_losing_values
    text = "x" * 2044
    rows = Array.new(32) { { "a" => text } }

    assert_equal "XP01", @codec.encode_page(rows).byteslice(0, 4)
    XitDB::Ruby.memory do |database|
      database.transaction { |root| root["rows"] = rows }

      assert_equal text, database.snapshot["rows"][0]["a"]
      assert_equal text, database.snapshot["rows"][31]["a"]
    end
  end

  def test_sequential_fallback_pages_validate_every_skipped_cell
    values = [nil, false, true, 0, -1, 256, 1.5, "text", "ascii".encode("US-ASCII"), "\xff".b,
              "latin".encode("ISO-8859-1")]
    rows = values.map { |value| { "a" => value } }
    bytes = XitDB::Ruby::PageEncoder.new.encode(rows)

    assert_equal "XP01", bytes.byteslice(0, 4)
    assert_equal rows.first, @codec.decode_row(bytes, 0)
    assert_equal rows.last, @codec.decode_row(bytes, rows.size - 1)
    # Nine schema bytes precede the first cell in this one-field page.
    bytes.setbyte(9, 255)

    assert_raises(XitDB::InvalidValueError) { @codec.decode_row(bytes, rows.size - 1) }
  end

  def test_new_profile_identifier_and_legacy_rejection_preserve_files
    XitDB::Ruby.memory { |database| assert_equal "rb04", database.core.header.hash_id }
    Dir.mktmpdir do |directory|
      %w[rb01 rb02 rb03].each do |identifier|
        path = File.join(directory, identifier)
        core = XitDB::Core::Database.open(path, hash_id: identifier, hash_size: 32)
        core.close
        original = File.binread(path)

        assert_raises(XitDB::ProfileMismatchError) { XitDB::Ruby.open(path) }
        assert_equal original, File.binread(path)
      end
    end
  end

  private

  def checksum(bytes)
    body = bytes.byteslice(0, bytes.bytesize - 32)
    body + Digest::SHA256.digest(body)
  end
end
