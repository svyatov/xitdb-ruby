# frozen_string_literal: true

require "English"
require "test_helper"
require "digest"
require "stringio"
require "timeout"

class StreamsTest < Minitest::Test
  def setup
    @db = XitDB.memory
  end

  def teardown
    @db.close unless @db.closed?
  end

  def test_io_copy_stream_and_writer_abort
    data = ("abc\0def\xff".b * 300_000).freeze
    expected_digest = Digest::SHA256.hexdigest(data)
    retained_writer = nil
    retained_reader = nil
    @db.transaction do |root|
      root.write_bytes("blob") do |io|
        retained_writer = io

        assert_equal data.bytesize, IO.copy_stream(StringIO.new(data), io)
        assert_equal data.bytesize, io.pos
        root["other"] = "kept"
      end
      assert_raises(RuntimeError) do
        root.write_bytes("blob") do |io|
          io.write("discarded")
          root["saved"] = "also kept"
          raise "abort"
        end
      end
      assert_equal "kept", root["other"]
      assert_equal "also kept", root["saved"]
    end
    @db.snapshot.open_bytes("blob") do |io|
      retained_reader = io

      assert_equal expected_digest, Digest::SHA256.hexdigest(io.read)
      io.rewind
      output = StringIO.new

      assert_equal data.bytesize, IO.copy_stream(io, output)
      assert_equal expected_digest, Digest::SHA256.hexdigest(output.string)
    end
    assert_raises(XitDB::ExpiredViewError) { retained_reader.read(1) }
    assert_raises(XitDB::ExpiredViewError) { retained_writer.write("x") }
  end

  def test_reader_positions_short_reads_and_output_buffers
    @db.transaction { |root| root["blob"] = "abcdef" }
    @db.snapshot.open_bytes("blob") do |io|
      assert_equal 6, io.size
      assert_equal 0, io.pos
      refute_predicate io, :eof?
      output = +"old"

      assert_same output, io.read(2, output)
      assert_equal "ab".b, output
      assert_equal Encoding::BINARY, output.encoding
      assert_equal 0, io.seek(-1, IO::SEEK_CUR)
      assert_equal "bcd", io.readpartial(3)
      assert_equal 0, io.seek(-1, IO::SEEK_END)
      assert_equal "f", io.read(100)
      assert_predicate io, :eof?
      assert_nil io.read(1, output)
      assert_empty output
      assert_equal "", io.read
      assert_equal "", io.read(0)
      assert_equal "", io.readpartial(0)
      assert_raises(EOFError) { io.readpartial(1, output) }
      assert_empty output
      assert_equal 0, io.seek(9)
      assert_equal 9, io.pos
      assert_nil io.read(1)
      assert_raises(Errno::EINVAL) { io.seek(-1) }
      assert_raises(Errno::EINVAL) { io.seek(0, 123) }
      assert_equal 9, io.pos
      assert_equal 0, io.rewind
      assert_equal "abcdef", io.read(nil, output)
      assert_same output, io.read(0, output)
    end
  end

  def test_empty_inline_and_binary_storage
    ["", "abcdefgh", "a\0b", "\xff".b, "a" * 65_537].each do |data|
      @db.transaction { |root| root.write_bytes("blob") { |io| assert_equal data.bytesize, io.write(data) } }

      @db.snapshot.open_bytes("blob") { |io| assert_equal data.b, io.read }
      assert_equal data.b, @db.snapshot["blob"].b
    end
  end

  def test_nonlocal_exits_discard_and_expire_streams
    writer = reader = nil
    @db.transaction do |root|
      root["blob"] = "before"
      result = root.write_bytes("blob") do |io|
        writer = io
        io.write("after")
        root["sibling"] = 1
        break :stopped
      end

      assert_equal :stopped, result
      assert_equal "before", root["blob"]
      assert_equal 1, root["sibling"]
      catch(:stop) do
        root.write_bytes("absent") do |io|
          io.write("no")
          throw :stop
        end
      end

      refute root.key?("absent")
      root.write_bytes("blob") { |io| io.write("done") }
    end

    assert_equal :stopped, @db.snapshot.open_bytes("blob") { |io|
      reader = io
      break :stopped
    }
    assert_raises(XitDB::ExpiredViewError) { reader.size }
    assert_raises(XitDB::ExpiredViewError) { writer.pos }
  end

  def test_overlapping_keys_ancestors_and_merges_reject_before_changes
    @db.transaction do |root|
      root["nested"] = { "blob" => "old", "sibling" => 0 }
      child = root["nested"]
      child.write_bytes("blob") do |io|
        assert_raises(XitDB::ConcurrentModificationError) { child["blob".b] = "old" }
        assert_raises(XitDB::ConcurrentModificationError) { child.delete("blob") }
        assert_raises(XitDB::ConcurrentModificationError) { child.clear }
        assert_raises(XitDB::ConcurrentModificationError) { root["nested"] = {} }
        assert_raises(XitDB::ConcurrentModificationError) { root.delete("nested") }
        assert_raises(XitDB::ConcurrentModificationError) { child.merge!({ "sibling" => 9, "blob" => "bad" }) }
        assert_raises(XitDB::ConcurrentModificationError) { child.write_bytes("blob") { flunk "overlap callback ran" } }
        child["sibling"] = 1
        child.write_bytes("second") { |second| second.write("two") }
        io.write("new")
      end

      assert_equal({ "blob" => "new", "sibling" => 1, "second" => "two" }, child.to_ruby)
      child.open_bytes("blob") do |io|
        assert_raises(XitDB::ConcurrentModificationError) { child["blob"] = "bad" }
        child["sibling"] = 2

        assert_equal "new", io.read
        child.open_bytes("blob") { |other| assert_equal "new", other.read }
      end
    end
  end

  def test_array_streams_reject_shifted_positions_and_allow_unrelated_edits
    [[], XitDB.linked_array].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"]
        items.push("first", "second", "third")
        items.write_bytes(-2) do |io|
          assert_raises(XitDB::ConcurrentModificationError) { items[1] = "bad" }
          assert_raises(XitDB::ConcurrentModificationError) { items.insert(0, "bad") }
          assert_raises(XitDB::ConcurrentModificationError) { items.delete_at(0) }
          assert_raises(XitDB::ConcurrentModificationError) { items.pop(2) }
          assert_raises(XitDB::ConcurrentModificationError) { items.clear }
          items[0] = "changed"
          items.push("last")
          items.delete_at(2)
          io.write("stream")
        end

        assert_equal %w[changed stream last], items.to_ruby
        items.open_bytes(-2) { |io| assert_equal "stream", io.read }
        items[1, 2].open_bytes(0) { |io| assert_equal "stream", io.read }
        items.write_bytes(4) { |io| io.write("gap") }

        assert_equal ["changed", "stream", "last", nil, "gap"], items.to_ruby
      end
    end
  end

  def test_invalid_values_readonly_and_closed_handles
    @db.transaction do |root|
      root["tagged"] = XitDB::Core::ByteValue.new("abc", format_tag: "xx")
      root["number"] = 1
      root["set"] = XitDB.set
      root["sorted"] = XitDB.sorted_map
      root["sorted"].write_bytes("a") { |io| io.write("sorted") }
      assert_raises(XitDB::InvalidValueError) { root.open_bytes("tagged") { flunk } }
      assert_raises(XitDB::InvalidValueError) { root.open_bytes("number") { flunk } }
      assert_raises(KeyError) { root.open_bytes("absent") { flunk } }
      assert_raises(TypeError) { root["set"].write_bytes("x") { flunk } }
      assert_raises(TypeError) { root["set"].open_bytes("x") { flunk } }
      assert_raises(ArgumentError) { root.write_bytes("missing_block") }
      assert_raises(ArgumentError) { root.open_bytes("number") }
    end
    snapshot = @db.snapshot
    assert_raises(XitDB::ReadOnlyError) { snapshot.write_bytes("x") { flunk } }
    snapshot["sorted"].open_bytes("a") do |io|
      assert_equal "sorted", io.read
      @db.close
      assert_raises(XitDB::ClosedError) { io.read(1) }
    end
  end

  def test_reads_are_bounded_and_skip_scalar_materialization
    data = "0123456789" * 30_000
    @db.transaction { |root| root["blob"] = data }
    core = @db.core
    original = core.method(:read_at)
    core.define_singleton_method(:read_at) do |offset, length, **options|
      raise "unbounded source read: #{length}" if length > 65_536

      original.call(offset, length, **options)
    end
    @db.snapshot.open_bytes("blob") do |io|
      assert_equal data, io.read
      io.rewind

      assert_equal data, io.readpartial(data.bytesize)
    end
  end

  def test_tagged_bytes_reject_before_reading_corrupt_metadata
    @db.close
    store = XitDB::Core::MemoryStore.new
    @db = XitDB::Database.new(core: XitDB::Core::Database.new(store: store), profile: XitDB::Profiles::Portable.new)
    @db.transaction { |root| root["tagged"] = XitDB::Core::ByteValue.new("long tagged payload", format_tag: "zz") }
    slot = @db.snapshot.adapter.lookup("tagged")
    store.write_at(slot.value, [(1 << 64) - 1].pack("Q>"))
    error = assert_raises(XitDB::InvalidValueError) do
      @db.snapshot.open_bytes("tagged") { flunk "tagged reader was yielded" }
    end
    assert_equal "stream requires untagged bytes", error.message
  end

  def test_io_argument_errors_and_conversion
    @db.transaction { |root| root["blob"] = "abc" }
    @db.snapshot.open_bytes("blob") do |io|
      assert_raises(TypeError) { io.readpartial(nil) }
      assert_raises(TypeError) { io.read("1") }
      assert_raises(ArgumentError) { io.read(-1) }
      assert_raises(RangeError) { io.read(1 << 100) }
      assert_raises(TypeError) { io.read(1, Object.new) }
      assert_raises(FrozenError) { io.read(1, "") }
      assert_equal 0, io.pos
      count = Object.new
      count.define_singleton_method(:to_int) { 1 }

      assert_equal "a", io.read(count)
      assert_equal "b", io.read(1.9)
      assert_equal 0, io.seek(1, :SET)
      assert_equal 0, io.seek(1, :CUR)
      assert_equal 0, io.seek(-1, :END)
      assert_equal "c", io.read
      assert_raises(TypeError) { io.seek(0, :INVALID) }
    end
    @db.transaction do |root|
      root.write_bytes("blob") do |io|
        assert_equal 3, io.write(123)
        assert_equal 0, io.write(nil)
      end
    end

    assert_equal "123", @db.snapshot["blob"]
  end

  def test_all_escaped_reader_operations_expire_even_after_close
    @db.transaction { |root| root["blob"] = "abc" }
    retained = nil
    @db.snapshot.open_bytes("blob") { |io| retained = io }
    @db.close

    [[:read], [:readpartial, 1], [:seek, 0], [:rewind], [:pos], [:size], [:eof?]].each do |arguments|
      assert_raises(XitDB::ExpiredViewError) { retained.public_send(*arguments) }
    end
  end

  def test_finalization_failure_restores_only_the_stream_assignment
    @db.transaction do |root|
      root["blob"] = "before"
      transaction = root.context.transaction
      append = transaction.method(:append)
      transaction.define_singleton_method(:append) do |bytes|
        result = append.call(bytes)
        raise IOError, "injected append failure" if bytes.bytesize > 1000

        result
      end
      checkpoint_length = nil
      assert_raises(IOError) do
        root.write_bytes("blob") do |io|
          io.write("x" * 100_000)
          root["sibling"] = "kept"
          checkpoint_length = transaction.length
        end
      end
      assert_equal checkpoint_length, transaction.length
      assert_equal "before", root["blob"]
      assert_equal "kept", root["sibling"]
      root.write_bytes("blob") { |io| io.write("after") }
    end

    assert_equal({ "blob" => "after", "sibling" => "kept" }, @db.snapshot.to_ruby)
  end

  def test_transaction_streams_reject_other_threads
    @db.transaction do |root|
      root["blob"] = "data"
      root.open_bytes("blob") do |io|
        error = Thread.new do
          io.read
        rescue StandardError
          $ERROR_INFO
        end.value

        assert_instance_of XitDB::TransactionStateError, error
      end
      root.write_bytes("blob") do |io|
        error = Thread.new do
          io.write("bad")
        rescue StandardError
          $ERROR_INFO
        end.value

        assert_instance_of XitDB::TransactionStateError, error
        io.write("good")
      end
    end

    assert_equal "good", @db.snapshot["blob"]
  end

  def test_close_waits_for_the_complete_chunked_read
    data = "x" * 200_000
    @db.transaction { |root| root["blob"] = data }
    entered = Queue.new
    release = Queue.new
    core = @db.core
    original = core.method(:read_at)
    blocked = false
    core.define_singleton_method(:read_at) do |offset, length, **options|
      result = original.call(offset, length, **options)
      if length == 65_536 && !blocked
        blocked = true
        entered << true
        release.pop
      end
      result
    end
    snapshot = @db.snapshot
    reader = Thread.new { snapshot.open_bytes("blob", &:read) }
    reader.report_on_exception = false
    Timeout.timeout(2) { entered.pop }
    closer = Thread.new { @db.close }
    closer.report_on_exception = false
    Timeout.timeout(2) { Thread.pass until closer.status == "sleep" || !closer.alive? }

    assert_predicate closer, :alive?, "close did not wait for the complete byte read"
    release << true

    assert_equal data, Timeout.timeout(2) { reader.value }
    Timeout.timeout(2) { closer.value }
  ensure
    [reader, closer].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  def test_reader_setup_pins_array_index_resolution_and_byte_metadata
    @db.transaction { |root| root["items"] = ["value"] }
    items = @db.snapshot["items"]
    entered = Queue.new
    release = Queue.new
    core = @db.core
    original = core.method(:read_at)
    blocked = false
    core.define_singleton_method(:read_at) do |*args, **options|
      result = original.call(*args, **options)
      unless blocked
        blocked = true
        entered << true
        release.pop
      end
      result
    end
    reader = Thread.new { items.open_bytes(-1, &:class) }
    reader.report_on_exception = false
    Timeout.timeout(2) { entered.pop }
    closer = Thread.new { @db.close }
    closer.report_on_exception = false
    Timeout.timeout(2) { Thread.pass until closer.status == "sleep" || !closer.alive? }

    assert_predicate closer, :alive?, "close did not wait for reader setup"
    release << true

    assert_equal XitDB::Streams::Reader, Timeout.timeout(2) { reader.value }
    Timeout.timeout(2) { closer.value }
  ensure
    [reader, closer].compact.each do |thread|
      thread.kill if thread.alive?
      begin
        thread.join
      rescue StandardError
        nil
      end
    end
  end

  def test_corrupt_byte_length_rejects_before_the_reader_callback
    @db.transaction { |root| root["blob"] = "long byte value" }
    snapshot = @db.snapshot
    stored = snapshot.adapter.lookup("blob")
    core = @db.core
    original = core.method(:read_at)
    core.define_singleton_method(:read_at) do |offset, length, **options|
      offset == stored.value && length == 8 ? [(1 << 64) - 1].pack("Q>") : original.call(offset, length, **options)
    end
    assert_raises(XitDB::CorruptionError) { snapshot.open_bytes("blob") { flunk "corrupt reader was yielded" } }
  end

  def test_rejected_removals_do_not_decode_the_active_value
    @db.transaction do |root|
      root["blob"] = "data"
      root["items"] = ["data"]
      core = @db.core
      original = core.method(:read_bytes)
      blocked_slot = nil
      core.define_singleton_method(:read_bytes) do |slot, **options|
        raise "decoded an active stream value" if slot == blocked_slot

        original.call(slot, **options)
      end
      blocked_slot = root.adapter.lookup("blob")

      root.open_bytes("blob") do
        assert_raises(XitDB::ConcurrentModificationError) { root.delete("blob") }
      end
      items = root["items"]
      items.open_bytes(0) do
        assert_raises(XitDB::ConcurrentModificationError) { items.delete_at(0) }
        assert_raises(XitDB::ConcurrentModificationError) { items.pop(1) }
      end
    end
  end

  def test_sparse_array_growth_cannot_fill_an_active_stream_position
    @db.transaction do |root|
      root["items"] = []
      items = root["items"]
      items.write_bytes(5) do |io|
        assert_raises(XitDB::ConcurrentModificationError) { items[6] = "bad" }
        assert_raises(XitDB::ConcurrentModificationError) { items.insert(6, "bad") }
        assert_raises(XitDB::ConcurrentModificationError) do
          items.write_bytes(6) { flunk "overlapping gap callback ran" }
        end
        items[4] = "sibling"
        io.write("stream")
      end

      assert_equal [nil, nil, nil, nil, "sibling", "stream"], items.to_ruby
    end
  end

  def test_array_reader_bounds_after_negative_index_normalization
    valid_indices = [[-3, "left"], [-1, "right"], [0, "left"], [2, "right"]]
    invalid_indices = [-4, -5, -6, -100, 3]
    [[], XitDB.linked_array].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        root["items"].push("left", "middle", "right")
      end
      items = @db.snapshot["items"]

      valid_indices.each do |index, expected|
        assert_equal expected, items.open_bytes(index, &:read)
      end
      invalid_indices.each do |index|
        assert_nil items[index]
        assert_raises(KeyError) { items.open_bytes(index) { flunk "out-of-range reader was yielded" } }
      end
    end
  end

  def test_slice_reader_bounds_use_the_visible_size
    [[], XitDB.linked_array].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        root["items"].push("left", "middle", "right")
      end
      items = @db.snapshot["items"]
      [
        [items[1, 1], [[0, "middle"], [-1, "middle"]], [-2, -100, 1]],
        [items[0, 2], [[0, "left"], [-2, "left"], [-1, "middle"]], [-3, -100, 2]],
        [items[1, 0], [], [-1, -100, 0]]
      ].each do |slice, valid, invalid|
        valid.each { |index, expected| assert_equal expected, slice.open_bytes(index, &:read) }
        invalid.each do |index|
          assert_nil slice[index]
          assert_raises(KeyError) { slice.open_bytes(index) { flunk "reader escaped visible slice bounds" } }
        end
      end
    end
  end

  def test_invalid_array_reader_cannot_bypass_stream_overlap_protection
    [[], XitDB.linked_array].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"]
        items.push("left", "middle", "right")
        assert_raises(KeyError) do
          items.open_bytes(-4) do |reader|
            items[2] = "changed"
            reader.read
          end
        end
        assert_equal %w[left middle right], items.to_ruby
        items.open_bytes(-1) do |reader|
          assert_raises(XitDB::ConcurrentModificationError) { items[2] = "changed" }
          assert_equal "right", reader.read
        end
      end
    end
  end
end
