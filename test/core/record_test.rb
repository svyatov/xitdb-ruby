# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class RecordTest < Minitest::Test
  Core = XitDB::Core

  def test_bounded_records_preserve_fields_and_compacted_sharing
    Dir.mktmpdir do |dir|
      source = Core::Database.memory
      source.transaction do |root|
        bytes = source.bytes("retained payload")
        slot = Core::Record.append(root.transaction, metadata: 42,
                                                     fields: [Core::Slot.int(-3), bytes, bytes])
        root.replace(slot)
      end
      before = source.root_cursor
      record = Core::Record.read(source, before.slot, bound: before.bound)

      assert_equal 42, record.metadata
      assert_equal Core::Slot.int(-3), record.fields.first
      assert_equal 35, source.read_at(before.slot.value, 35, bound: before.bound).bytesize
      source.transaction { |root| root.replace(Core::Slot.uint(9)) }

      assert_equal record.fields, Core::Record.read(source, before.slot, bound: before.bound).fields

      source.transaction { |root| root.replace(before.slot) }
      compacted = source.compact(to: File.join(dir, "compact"))
      copied = Core::Record.read(compacted, compacted.root_cursor.slot, bound: compacted.committed_size)

      assert_equal 42, copied.metadata
      assert_equal copied.fields[1], copied.fields[2]
      assert_equal "retained payload", compacted.read_bytes(copied.fields[1]).bytes
    ensure
      compacted&.close
      source&.close
    end
  end

  def test_invalid_records_fail_before_reading_unbounded_fields
    source = Core::Database.memory
    source.transaction do |root|
      transaction = root.transaction
      size = transaction.length
      assert_raises(ArgumentError) do
        Core::Record.append(transaction, metadata: 0, fields: Array.new(33, Core::Slot.null))
      end
      assert_raises(RangeError) { Core::Record.append(transaction, metadata: -1, fields: []) }
      assert_raises(TypeError) { Core::Record.append(transaction, metadata: 0, fields: [nil]) }
      assert_equal size, transaction.length

      [[0, 33].pack("NN"), [0, 1].pack("NN") + Core::Slot.new(tag: 127).to_bytes,
       [0, 1].pack("NN")].each do |bytes|
        pointer = transaction.append(bytes)
        slot = Core::Slot.new(tag: :record, value: pointer)
        assert_raises(XitDB::CorruptionError) do
          Core::Record.read(source, slot, bound: pointer + bytes.bytesize)
        end
      end
    end
  ensure
    source&.close
  end

  def test_compaction_keeps_record_cycles_and_rejects_excessive_counts
    Dir.mktmpdir do |dir|
      source = Core::Database.memory
      source.transaction do |root|
        slot = Core::Record.append(root.transaction, metadata: 7, fields: [Core::Slot.null])
        root.transaction.write_at(slot.value + 8, slot.to_bytes)
        root.replace(slot)
      end
      compacted = source.compact(to: File.join(dir, "cycle"))
      cursor = compacted.root_cursor
      record = Core::Record.read(compacted, cursor.slot, bound: cursor.bound)

      assert_equal cursor.slot, record.fields.first
      source.transaction do |root|
        pointer = root.transaction.append([0, 33].pack("NN"))
        root.replace(Core::Slot.new(tag: :record, value: pointer))
      end
      assert_raises(XitDB::CorruptionError) { source.compact(to: File.join(dir, "invalid")) }
    ensure
      compacted&.close
      source&.close
    end
  end

  def test_empty_and_full_records_respect_snapshot_bounds_and_writer_lifetime
    source = Core::Database.memory
    writer = nil
    source.transaction do |root|
      writer = root.transaction
      root.replace(Core::Record.append(writer, metadata: 0, fields: []))
    end
    before = source.root_cursor

    assert_empty Core::Record.read(source, before.slot, bound: before.bound).fields

    source.transaction do |root|
      root.replace(Core::Record.append(root.transaction, metadata: 0xffff_ffff,
                                                         fields: Array.new(32, Core::Slot.int(-1))))
    end
    latest = source.root_cursor
    record = Core::Record.read(source, latest.slot, bound: latest.bound)

    assert_equal 0xffff_ffff, record.metadata
    assert_equal Array.new(32, Core::Slot.int(-1)), record.fields
    assert_raises(XitDB::CorruptionError) { Core::Record.read(source, latest.slot, bound: before.bound) }
    assert_raises(XitDB::InvalidValueError) { Core::Record.read(source, Core::Slot.null, bound: latest.bound) }
    assert_raises(XitDB::ExpiredViewError) { Core::Record.append(writer, metadata: 0, fields: []) }
  ensure
    source&.close
  end
end
