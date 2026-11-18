# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "xitdb/verification/scan"

# Captures and reads one checked snapshot through an existing descriptor.
class VerificationScanTest < Minitest::Test
  Core = XitDB::Core

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "source")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_capture_survives_append
    XitDB.open(@path) do |writer|
      17.times { |index| writer.transaction { |root| root["index"] = index } }
      original_bound = File.size(@path)
      scan do |cursor|
        original_slot = cursor.root
        writer.transaction { |root| root["index"] = 17 }

        assert_equal original_bound, cursor.bound
        assert_equal original_slot, Core::Slot.parse(cursor.read(cursor.root_offset, Core::Slot::SIZE))
        assert_raises(XitDB::VerificationError) { cursor.read(original_bound, 1) }
      end
    end
  end

  def test_supported_headers_and_virtual_root
    versions = [1, 2]
    [%w[sha1 20], %w[sha2 32], %w[sha2 48], %w[sha2 64], %w[rb05 32]].each do |id, width|
      versions.each do |version|
        Core::Database.open(@path, hash_id: id, hash_size: width.to_i, format_version: version, &:close)
        scan do |cursor|
          assert_equal(id == "rb05" ? :ruby : :portable, cursor.profile)
          assert_nil cursor.root
          assert_equal version, cursor.header.version
        end
        File.unlink(@path)
      end
    end
  end

  def test_missing_and_empty_file
    assert_raises(Errno::ENOENT) { scan { flunk } }
    File.binwrite(@path, "")
    error = assert_raises(XitDB::VerificationError) { scan { flunk } }
    assert_equal [:header, 0, nil], [error.check, error.offset, error.path]
    assert_equal 0, File.size(@path)
  end

  def test_unsupported_headers
    [["rb04", 32], ["rb05", 20], ["sha2", 20], ["????", 4]].each do |id, width|
      Core::Database.open(@path, hash_id: id, hash_size: width, &:close)
      assert_raises(XitDB::UnsupportedVerificationFormatError) { scan { flunk } }
      File.unlink(@path)
    end
    Core::Database.open(@path, &:close)
    File.open(@path, "r+b") { |io| io.pwrite([7].pack("n"), 4) }
    assert_raises(XitDB::UnsupportedVerificationFormatError) { scan { flunk } }
  end

  def test_invalid_trailer
    Core::Database.open(@path, &:close)
    data = File.binread(@path)
    data.setbyte(-1, data.getbyte(-1) ^ 1)
    File.binwrite(@path, data)
    error = assert_raises(XitDB::VerificationError) { scan { flunk } }
    assert_equal [:trailer, data.bytesize - 25], [error.check, error.offset]
  end

  def test_invalid_committed_size
    Core::Database.open(@path, &:close)
    File.open(@path, "r+b") { |io| io.pwrite([1].pack("Q>"), 24) }
    error = assert_raises(XitDB::VerificationError) { scan { flunk } }

    assert_equal [:committed_size, 24], [error.check, error.offset]
  end

  def test_empty_history_array_has_no_root
    Core::Database.open(@path) { |db| db.transaction { |root| Core::ArrayList.new(root) } }

    scan { |cursor| assert_nil cursor.root }
  end

  def test_non_history_root
    Core::Database.open(@path) { |db| db.transaction { |root| root.replace(Core::Slot.uint(1)) } }
    error = assert_raises(XitDB::VerificationError) { scan { flunk } }

    assert_equal :history, error.check
  end

  def test_stored_empty_slot_is_an_invalid_root
    Core::Database.open(@path) do |db|
      db.transaction { |root| Core::ArrayList.new(root).append(Core::Slot.new) }
    end
    error = assert_raises(XitDB::VerificationError) { scan { flunk } }
    assert_equal :root, error.check
  end

  def test_exception_closes_descriptor
    Core::Database.open(@path, &:close)
    retained = nil
    assert_raises(Interrupt) do
      scan do |cursor|
        retained = cursor
        raise Interrupt
      end
    end
    assert_raises(XitDB::ClosedError) { retained.read(retained.header.data_offset, 1) }
  end

  def test_limits
    %i[depth references path_bytes scalar_bytes codec_bytes summary_bytes comparison_bytes].each do |limit_name|
      budget = XitDB::Verification::Budget.new(limit_name => 1)
      operation = -> { budget.reserve!(limit_name) }

      budget.with(limit_name, 1) do
        assert_equal limit_name, assert_raises(XitDB::VerificationLimitError) { operation.call }.limit
      end
      operation.call
    end
  end

  def test_path_truncation
    budget = XitDB::Verification::Budget.new
    path = budget.path("$", "x" * 8192)

    assert_operator path.bytesize, :<=, 1024
    assert path.end_with?("[...]")
    assert_equal path, budget.path(path, "more")
  end

  private

  def scan(&)
    XitDB::Verification::Scan.open(@path, &)
  end
end
