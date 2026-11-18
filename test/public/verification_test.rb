# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class PublicVerificationTest < Minitest::Test
  Core = XitDB::Core

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "restore.xit")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_readonly_source_and_unpublished_tail
    XitDB.open(@path, hash: :sha384) { |db| db.transaction { |root| root["large"] = "x" * 150_000 } }
    committed = File.size(@path)
    File.open(@path, "ab") { |io| io.write("unfinished") }
    File.chmod(0o444, @path)
    original_bytes = File.binread(@path)

    result = XitDB.verify!(@path)

    assert_instance_of XitDB::VerificationResult, result
    assert_equal [:portable, "sha2", 48, committed, []], result.deconstruct
    assert_predicate result, :frozen?
    assert_predicate result.hash_id, :frozen?
    assert_predicate result.codec_ids, :frozen?
    assert_equal original_bytes, File.binread(@path)
  end

  def test_ruby_codec_inventory
    require "xitdb/ruby"
    codec = XitDB::Ruby::Codec.new(id: "app/v1", type: Struct.new(:bytes), dump: lambda(&:bytes),
                                   load: ->(*) { flunk "application loader called" })
    XitDB::Ruby.open(@path, codecs: [codec]) do |db|
      db.transaction { |root| root[:items] = [codec.type.new("first"), codec.type.new("second")] }
    end
    original_bytes = File.binread(@path)

    result = XitDB.verify!(@path)

    assert_equal [:ruby, "rb05", 32, original_bytes.bytesize, [codec.id]], result.deconstruct
    assert_predicate result.codec_ids.first, :frozen?
    assert_equal original_bytes, File.binread(@path)
  end

  def test_empty_snapshot_missing_and_zero_byte_sources
    assert_raises(Errno::ENOENT) { XitDB.verify!(@path) }
    refute_path_exists @path
    XitDB.open(@path, &:close)

    assert_equal File.size(@path), XitDB.verify!(@path).committed_size
    File.binwrite(@path, "")
    error = assert_raises(XitDB::VerificationError) { XitDB.verify!(@path) }
    assert_equal [:header, 0], [error.check, error.offset]
    assert_equal "", File.binread(@path)
  end

  def test_unsupported_and_malformed_root
    legacy = File.join(@dir, "legacy")
    Core::Database.open(legacy, hash_id: "rb04", hash_size: 32, &:close)
    assert_raises(XitDB::UnsupportedVerificationFormatError) { XitDB.verify!(legacy) }
    Core::Database.open(@path) do |db|
      db.transaction { |root| Core::ArrayList.new(root).append(Core::Slot.int(1)) }
    end
    original_bytes = File.binread(@path)
    error = assert_raises(XitDB::VerificationError) { XitDB.verify!(@path) }
    assert_equal :root, error.check
    assert_equal "$", error.path
    assert_equal original_bytes, File.binread(@path)
  end

  def test_first_defect_in_array
    first = XitDB.open(@path) do |db|
      snapshot = db.transaction { |root| root["items"] = [1, 2] }
      array = snapshot["items"].slot.value
      File.open(@path, "rb") { |io| io.pread(8, array + 8).unpack1("Q>") }
    end
    File.open(@path, "r+b") { |io| io.pwrite(Core::Slot.new(tag: 123).to_bytes * 2, first) }
    original_bytes = File.binread(@path)
    error = assert_raises(XitDB::VerificationError) { XitDB.verify!(@path) }
    assert_equal [:slot, first, '$/"items"/0'], [error.check, error.offset, error.path]
    assert_equal original_bytes, File.binread(@path)
  end

  def test_only_old_value_is_damaged
    offset = XitDB.open(@path) do |db|
      previous = db.transaction { |root| root["entry"] = "old long value" }
      db.transaction { |root| root["entry"] = "new long value" }
      previous.adapter.lookup("entry").value
    end
    File.open(@path, "r+b") { |io| io.pwrite("\xff".b * 8, offset) }
    original_bytes = File.binread(@path)

    assert_equal original_bytes.bytesize, XitDB.verify!(@path).committed_size
    assert_equal original_bytes, File.binread(@path)
  end

  def test_scan_keeps_original_descriptor_and_boundary
    XitDB.open(@path) { |db| db.transaction { |root| root["first"] = 1 } }
    committed = File.size(@path)
    saved = File.join(@dir, "saved")
    replacement = File.join(@dir, "replacement")
    File.binwrite(replacement, "replacement")
    trace = TracePoint.new(:call) do |event|
      next unless event.method_id == :verify! && event.defined_class == XitDB::Verification::Graph

      File.rename(@path, saved)
      File.rename(replacement, @path)
      Core::Database.open(saved) do |db|
        db.transaction { |root| Core::ArrayList.new(root).append(Core::Slot.uint(42)) }
      end
    end

    result = trace.enable { XitDB.verify!(@path) }

    assert_equal committed, result.committed_size
    assert_equal "replacement", File.binread(@path)
    assert_equal :root, assert_raises(XitDB::VerificationError) { XitDB.verify!(saved) }.check
  end

  def test_os_read_failure
    XitDB.open(@path, &:close)
    trace = TracePoint.new(:call) do |event|
      raise Errno::EIO if event.method_id == :read_file && event.defined_class == Core::FileStore
    end
    original_bytes = File.binread(@path)

    assert_raises(Errno::EIO) { trace.enable { XitDB.verify!(@path) } }
    assert_equal original_bytes, File.binread(@path)
  end

  def test_depth_limit_is_incomplete_verification
    nested = 150.times.reduce(0) { |value, _| [value] }
    XitDB.open(@path) { |db| db.transaction { |root| root["nested"] = nested } }
    original_bytes = File.binread(@path)

    error = assert_raises(XitDB::VerificationLimitError) { XitDB.verify!(@path) }
    assert_equal :depth, error.limit
    refute_kind_of XitDB::CorruptionError, error
    assert_equal original_bytes, File.binread(@path)
  end
end
