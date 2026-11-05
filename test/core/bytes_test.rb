# frozen_string_literal: true

# Regression tests for raw byte reads and writes, bounded transfers, and validation before mutation.

require_relative "../test_helper"
require_relative "../support/fault_store"

# Covers raw byte reads and writes, bounded transfers, and validation before mutation.
# @api private
class BytesTest < Minitest::Test
  Core = XitDB::Core

  # Checks automatic capacity includes prefix and tag bytes.
  def test_automatic_capacity_includes_prefix_and_tag_bytes
    core = Core::Database.memory
    core.transaction do |root|
      plain = Core::Bytes.append(root.transaction, size: 7, prefix: "p") { "1234567" }
      tagged = Core::Bytes.append(root.transaction, size: 5, prefix: "p", format_tag: "xy") { "12345" }
      external = Core::Bytes.append(root.transaction, size: 6, prefix: "p", format_tag: "xy") { "123456" }

      assert_equal :short_bytes, plain.tag
      assert_equal :short_bytes, tagged.tag
      assert_equal :bytes, external.tag
      assert_equal "p1234567", core.read_bytes(plain, bound: root.transaction.length).bytes
      assert_equal "p12345", core.read_bytes(tagged, bound: root.transaction.length).bytes
      assert_equal "p123456", core.read_bytes(external, bound: root.transaction.length).bytes
    end
  end

  # Checks scalar facade captures mutable input before store callbacks.
  def test_scalar_facade_captures_mutable_input_before_store_callbacks
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    input = +"123456789"
    core.transaction do |root|
      store.fault = ->(name, _) { input.replace("changed!!") if name == :append }
      root.replace(core.bytes(input))
      store.fault = nil
    end

    assert_equal "changed!!", input
    assert_equal "123456789", core.root_cursor.read_bytes.bytes
  end

  # Checks copy bounds large IO read requests.
  def test_copy_bounds_large_io_read_requests
    core = Core::Database.memory
    requests = []
    source = StringIO.new("x" * 65_537)
    source.define_singleton_method(:read) do |length|
      requests << length
      super(length)
    end
    core.transaction do |root|
      root.replace(Core::Bytes.copy(source, size: 65_537, database: core, transaction: root.transaction))
    end

    assert_equal [65_536, 1], requests
    assert_equal "x" * 65_537, core.root_cursor.read_bytes.bytes
  end

  # Checks empty untagged external source and nonbyte rejection.
  def test_empty_untagged_external_source_and_nonbyte_rejection
    core = Core::Database.memory
    core.transaction do |root|
      slot = Core::Bytes.append(root.transaction, size: 0, representation: :external) { flunk "empty source" }

      assert_equal :bytes, slot.tag
      source = Core::Bytes.open(core, slot, bound: root.transaction.length)

      assert_nil source.format_tag
      assert_equal "".b, source.read(0, 0)
      assert_raises(XitDB::InvalidValueError) { Core::Bytes.open(core, Core::Slot.uint(1), bound: root.transaction.length) }
      error = assert_raises(XitDB::InvalidValueError) { Core::Bytes.locate(core, Core::Slot.uint(1), bound: root.transaction.length) }
      assert_equal "stream requires untagged bytes", error.message
    end
  end

  # Checks writer requires an active transaction even for inline values.
  def test_writer_requires_an_active_transaction_even_for_inline_values
    core = Core::Database.memory
    expired = nil
    core.transaction { |root| expired = root.transaction }
    assert_raises(XitDB::ExpiredViewError) { Core::Bytes.append(expired, size: 0) }
  end

  # Checks writer accepts the unsigned size boundary.
  def test_writer_accepts_the_unsigned_size_boundary
    core = Core::Database.memory
    original = IOError.new("stop before huge payload")
    error = assert_raises(IOError) do
      core.transaction do |root|
        Core::Bytes.append(root.transaction, size: (1 << 64) - 1) { raise original }
      end
    end
    assert_same original, error
    assert_empty core.root_cursor.slot
  end

  # Checks writer rejects nonstring and oversized tags without IO.
  def test_writer_rejects_nonstring_and_oversized_tags_without_io
    core = Core::Database.memory
    core.transaction do |root|
      before = root.transaction.length
      assert_raises(ArgumentError) { Core::Bytes.append(root.transaction, size: 1, format_tag: 12) { flunk "invalid tag" } }
      assert_raises(ArgumentError) { Core::Bytes.append(root.transaction, size: 1, format_tag: "xyz") { flunk "invalid tag" } }
      assert_equal before, root.transaction.length
    end
  end

  # Checks writer accepts two tag bytes in any string encoding.
  def test_writer_accepts_two_tag_bytes_in_any_string_encoding
    core = Core::Database.memory
    core.transaction do |root|
      tag = "xy".encode(Encoding::UTF_16BE).byteslice(0, 2)
      begin
        slot = Core::Bytes.append(root.transaction, size: 1, format_tag: tag) { "a" }
      rescue Encoding::CompatibilityError => e
        flunk "valid binary tag rejected: #{e.message}"
      end

      assert_equal "\0x".b, Core::Bytes.open(core, slot, bound: root.transaction.length).format_tag
      assert_equal Encoding::UTF_16BE, tag.encoding
    end
  end

  # Checks that source validates the complete tag extent.
  def test_source_validates_the_complete_tag_extent
    core = Core::Database.memory
    core.transaction do |root|
      slot = core.bytes("123456789", format_tag: "xy")
      assert_raises(XitDB::CorruptionError) do
        Core::Bytes.open(core, slot, bound: root.transaction.length - 1)
      end
      source = Core::Bytes.open(core, slot, bound: root.transaction.length)

      assert_equal "xy", source.format_tag
    end
  end

  # Checks source keeps its size and reads after later database growth.
  def test_source_keeps_its_size_and_reads_after_later_database_growth
    core = Core::Database.memory
    core.transaction { |root| root.replace(core.bytes("123456789")) }
    old = core.root_cursor
    source = Core::Bytes.open(core, old.slot, bound: old.bound)
    core.transaction { |root| root.replace(core.bytes("a later and larger value")) }

    assert_equal 9, source.size
    assert_equal "123456789", source.read(0, 9)
    assert_raises(XitDB::CorruptionError) { Core::Bytes.open(core, core.root_cursor.slot, bound: old.bound) }
    error = assert_raises(XitDB::InvalidValueError) { source.read(0, 10) }
    assert_equal "truncated byte payload", error.message
    assert_equal "".b, source.read(9, 0)
  end

  # Checks inline and external sources check closed handles including zero reads.
  def test_inline_and_external_sources_check_closed_handles_including_zero_reads
    core = Core::Database.memory
    inline = external = nil
    core.transaction do |root|
      inline = Core::Bytes.open(core, core.bytes("abc"), bound: root.transaction.length)
      external = Core::Bytes.open(core, core.bytes("123456789"), bound: root.transaction.length)

      assert_equal "".b, inline.read(3, 0)
    end
    core.close
    assert_raises(XitDB::ClosedError) { inline.read(0, 1) }
    assert_raises(XitDB::ClosedError) { inline.read(3, 0) }
    assert_raises(XitDB::ClosedError) { external.read(9, 0) }
  end

  # Checks sources reject invalid logical ranges and types.
  def test_sources_reject_invalid_logical_ranges_and_types
    core = Core::Database.memory
    core.transaction do |root|
      source = Core::Bytes.open(core, core.bytes("abc"), bound: root.transaction.length)
      assert_raises(TypeError) { source.read(0, "1") }
      assert_raises(TypeError) { source.read(nil, 0) }
      assert_raises(XitDB::InvalidValueError) { source.read(0, -1) }
      assert_raises(XitDB::InvalidValueError) { source.read(4, 0) }
      assert_raises(XitDB::InvalidValueError) { source.read(2, 2) }
    end
  end

  # Checks source failure after one chunk preserves exception and transaction rollback.
  def test_source_failure_after_one_chunk_preserves_exception_and_transaction_rollback
    store = Core::MemoryStore.new
    core = Core::Database.new(store: store)
    original = IOError.new("source failed")
    calls = []
    error = assert_raises(IOError) do
      core.transaction do |root|
        root.replace(Core::Bytes.append(root.transaction, size: 65_537) do |position, length|
          calls << [position, length]
          raise original if position == 65_536

          "a".b * length
        end)
      end
    end
    assert_same original, error
    assert_equal [[0, 65_536], [65_536, 1]], calls
    assert_equal 62, store.length
    assert_equal 62, core.committed_size
    assert_empty core.root_cursor.slot
  end

  # Checks store failure propagates without writer cleanup or retry.
  def test_store_failure_propagates_without_writer_cleanup_or_retry
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    original = IOError.new("store failed")
    core.transaction do |root|
      store.events.clear
      store.fault = ->(name, _) { raise original if name == :append }
      error = assert_raises(IOError) { Core::Bytes.append(root.transaction, size: 9) { flunk "source read after failed header" } }
      assert_same original, error
      assert_equal([:append], store.events.map(&:first).reject { |name| name == :closed? })
      store.fault = nil
    end
  end

  # Checks source captures metadata once without reading the payload.
  def test_source_captures_metadata_once_without_reading_the_payload
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    core.transaction do |root|
      slot = core.bytes("123456789", format_tag: "xy")
      store.events.clear
      source = Core::Bytes.open(core, slot, bound: root.transaction.length)
      reads = store.events.select { |name, args| name == :read_at && args.last.positive? }.map(&:last)

      assert_equal [[slot.value, 8], [slot.value + 17, 2]], reads
      store.events.clear

      assert_equal "12", source.read(0, 2)
      assert_equal "89", source.read(7, 2)
      assert_equal 9, source.size
      assert_equal "xy", source.format_tag
      reads = store.events.select { |event| event.first == :read_at }.map(&:last)

      assert_equal [[slot.value + 8, 2], [slot.value + 15, 2]], reads
    end
  end

  # Checks writer rejects combined size overflow before appending.
  def test_writer_rejects_combined_size_overflow_before_appending
    core = Core::Database.memory
    core.transaction do |root|
      before = root.transaction.length
      assert_raises(RangeError) { Core::Bytes.append(root.transaction, size: (1 << 64) - 1, prefix: "p") { flunk "overflow read" } }
      assert_equal before, root.transaction.length
    end
  end

  # Checks that writer validates tag before reading or appending.
  def test_writer_validates_tag_before_reading_or_appending
    core = Core::Database.memory
    core.transaction do |root|
      before = root.transaction.length
      assert_raises(ArgumentError) { Core::Bytes.append(root.transaction, size: 1, format_tag: "x") { flunk "invalid tag read" } }
      assert_equal before, root.transaction.length
    end
  end

  # Checks that writer validates representation before reading or appending.
  def test_writer_validates_representation_before_reading_or_appending
    core = Core::Database.memory
    core.transaction do |root|
      before = root.transaction.length
      assert_raises(ArgumentError) { Core::Bytes.append(root.transaction, size: 1, representation: :other) { flunk "invalid representation read" } }
      assert_equal before, root.transaction.length
    end
  end

  # Checks that writer validates prefix type before reading or appending.
  def test_writer_validates_prefix_type_before_reading_or_appending
    core = Core::Database.memory
    core.transaction do |root|
      before = root.transaction.length
      assert_raises(TypeError) { Core::Bytes.append(root.transaction, size: 1, prefix: nil) { flunk "invalid prefix read" } }
      assert_equal before, root.transaction.length
    end
  end

  # Checks that writer validates size type before reading or appending.
  def test_writer_validates_size_type_before_reading_or_appending
    core = Core::Database.memory
    core.transaction do |root|
      before = root.transaction.length
      assert_raises(TypeError) { Core::Bytes.append(root.transaction, size: 1.0) { flunk "invalid size read" } }
      assert_equal before, root.transaction.length
    end
  end

  # Checks that writer validates negative sizes before reading or appending.
  def test_writer_validates_negative_sizes_before_reading_or_appending
    core = Core::Database.memory
    core.transaction do |root|
      before = root.transaction.length
      assert_raises(ArgumentError) { Core::Bytes.append(root.transaction, size: -1) { flunk "invalid size read" } }
      assert_equal before, root.transaction.length
    end
  end

  # Checks writer rejects a missing block result.
  def test_writer_rejects_a_missing_block_result
    core = Core::Database.memory

    core.transaction do |root|
      assert_raises(EOFError) { Core::Bytes.append(root.transaction, size: 1) }
    end
  end

  # Checks writer rejects a nonstring block result.
  def test_writer_rejects_a_nonstring_block_result
    core = Core::Database.memory

    core.transaction do |root|
      assert_raises(TypeError) { Core::Bytes.append(root.transaction, size: 1) { 1 } }
    end
  end

  # Checks writer rejects a nil block result.
  def test_writer_rejects_a_nil_block_result
    core = Core::Database.memory

    core.transaction do |root|
      assert_raises(EOFError) { Core::Bytes.append(root.transaction, size: 1) { nil } }
    end
  end

  # Checks writer rejects an oversized block result before appending it.
  def test_writer_rejects_an_oversized_block_result_before_appending_it
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    core.transaction do |root|
      store.events.clear
      assert_raises(ArgumentError) { Core::Bytes.append(root.transaction, size: 9) { "x" * 10 } }
      appends = store.events.select { |event| event.first == :append }.map { |_, args| args.first }

      assert_equal [[9].pack("Q>")], appends
      root.transaction.cancel_publication
    end
  end

  # Checks writer rejects a short block result.
  def test_writer_rejects_a_short_block_result
    core = Core::Database.memory
    core.transaction do |root|
      before = root.transaction.length
      assert_raises(EOFError) { Core::Bytes.append(root.transaction, size: 3) { "ab" } }
      assert_equal before, root.transaction.length
    end
  end

  # Checks writer transfers a large prefix and payload in bounded chunks.
  def test_writer_transfers_a_large_prefix_and_payload_in_bounded_chunks
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    prefix = "p".b * 65_537
    payload = "q".b * 65_539
    calls = []
    core.transaction do |root|
      store.events.clear
      slot = Core::Bytes.append(root.transaction, size: payload.bytesize, prefix: prefix,
                                                  format_tag: "xy") do |position, length|
        calls << [position, length]
        payload.byteslice(position, length)
      end
      source = Core::Bytes.open(core, slot, bound: root.transaction.length)

      assert_equal 131_076, source.size
      assert_equal prefix + payload, source.read(0, source.size)
      assert_equal "xy", source.format_tag
      assert_equal [[0, 65_536], [65_536, 3]], calls
      assert(store.events.select { |event| event.first == :append }.all? { |_, args| args.first.bytesize <= 65_536 })
    end
    assert_equal "p" * 65_537, prefix
    assert_equal "q" * 65_539, payload
  end

  # Checks source rejects a noninteger position.
  def test_source_rejects_a_noninteger_position
    core = Core::Database.memory
    core.transaction do |root|
      source = Core::Bytes.open(core, core.bytes("123456789"), bound: root.transaction.length)
      assert_raises(TypeError) { source.read(0.5, 1) }
    end
  end

  # Checks source rejects a negative position.
  def test_source_rejects_a_negative_position
    core = Core::Database.memory
    core.transaction do |root|
      source = Core::Bytes.open(core, core.bytes("abc"), bound: root.transaction.length)
      error = assert_raises(XitDB::InvalidValueError) { source.read(-1, 1) }
      assert_equal "truncated byte payload", error.message
    end
  end

  # Checks external empty record keeps its tag and skips payload reads.
  def test_external_empty_record_keeps_its_tag_and_skips_payload_reads
    core = Core::Database.memory
    core.transaction do |root|
      slot = Core::Bytes.append(root.transaction, size: 0, format_tag: "\xff\0".b, representation: :external) { flunk "empty payload" }

      assert_equal :bytes, slot.tag
      source = Core::Bytes.open(core, slot, bound: root.transaction.length)

      assert_equal 0, source.size
      assert_equal "\xff\0".b, source.format_tag
      assert_predicate source.format_tag, :frozen?
      assert_equal Encoding::BINARY, source.format_tag.encoding
      assert_equal "".b, source.read(0, 0)
      assert_equal [0].pack("Q>") + "\xff\0".b, root.transaction.read_at(slot.value, 10)
    end
  end

  # Checks append captures automatic nul payload once.
  def test_append_captures_automatic_nul_payload_once
    core = Core::Database.memory
    core.transaction do |root|
      calls = []
      slot = Core::Bytes.append(root.transaction, size: 3) do |position, length|
        calls << [position, length]
        "a\0b".b.byteslice(position, length)
      end

      assert_equal :bytes, slot.tag
      assert_equal [[0, 3]], calls
      assert_equal "a\0b".b, Core::Bytes.open(core, slot, bound: root.transaction.length).read(0, 3)
    end
  end

  # Checks locate preserves inline and external result shapes.
  def test_locate_preserves_inline_and_external_result_shapes
    core = Core::Database.memory
    core.transaction do |root|
      inline = core.bytes("abc")
      external = core.bytes("123456789")

      assert_equal ["abc".b, 3], Core::Bytes.locate(core, inline, bound: root.transaction.length)
      data, = Core::Bytes.locate(core, inline, bound: root.transaction.length)

      refute_predicate data, :frozen?
      data.replace("xyz")

      assert_equal "abc", Core::Bytes.locate(core, inline, bound: root.transaction.length).first
      assert_equal [external.value + 8, 9], Core::Bytes.locate(core, external, bound: root.transaction.length)
      error = assert_raises(XitDB::InvalidValueError) do
        Core::Bytes.locate(core, core.bytes("abc", format_tag: "xy"), bound: root.transaction.length)
      end
      assert_equal "stream requires untagged bytes", error.message
    end
  end

  # Checks copy accepts progressing short IO reads.
  def test_copy_accepts_progressing_short_io_reads
    core = Core::Database.memory
    source = StringIO.new("123456789abc")
    # Supplies a controlled source read for byte-transfer assertions.
    def source.read(length)
      super([length, 3].min)
    end
    core.transaction do |root|
      root.replace(Core::Bytes.copy(source, size: 12, database: core, transaction: root.transaction))
    end

    assert_equal "123456789abc", core.root_cursor.read_bytes.bytes
  end

  # Checks copy small value keeps single read behavior.
  def test_copy_small_value_keeps_single_read_behavior
    core = Core::Database.memory
    source = StringIO.new("abc")
    core.transaction do |root|
      slot = Core::Bytes.copy(source, size: 8, database: core, transaction: root.transaction)

      assert_equal :short_bytes, slot.tag
      assert_equal "abc", core.read_bytes(slot).bytes
    end
  end
end
