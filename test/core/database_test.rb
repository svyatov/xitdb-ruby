# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "weakref"
require_relative "../support/fault_store"

class DatabaseTest < Minitest::Test
  Core = XitDB::Core

  def test_empty_initialization_can_be_disabled_without_changing_raw_defaults
    store = Core::MemoryStore.new
    assert_raises(XitDB::CorruptionError) { Core::Database.new(store: store, initialize_empty: false) }
    assert_equal 0, store.length
    core = Core::Database.new(store: store)
    assert_equal 62, core.committed_size
    existing = Core::Database.new(store: store, initialize_empty: false)
    assert existing.root_cursor.slot.empty?
    Dir.mktmpdir do |dir|
      path = File.join(dir, "empty.xit")
      File.binwrite(path, "")
      assert_raises(XitDB::CorruptionError) { Core::Database.open(path, initialize_empty: false) }
      assert_equal 0, File.size(path)
      Core::Database.open(path) { |raw| assert_equal 62, raw.committed_size }
      assert_equal 62, File.size(path)
    end
  ensure
    store&.close
  end

  def test_empty_file_and_exception_rollback
    core = Core::Database.memory(file_id: 1)
    assert_equal 62, core.committed_size
    error = RuntimeError.new("abort")
    assert_same error, assert_raises(RuntimeError) {
      core.transaction { |cursor| cursor.replace(core.bytes("new")); raise error }
    }
    assert core.root_cursor.slot.empty?
    assert_equal 62, core.committed_size
  end

  def test_scalars_and_old_cursor_keep_exact_bits
    core = Core::Database.memory
    old = core.root_cursor
    [Core::Slot.null, Core::Slot.int(-(1 << 63)), Core::Slot.uint((1 << 64) - 1),
     Core::Slot.float(-0.0), Core::Slot.float(Float::INFINITY)].each do |slot|
      core.transaction { |cursor| cursor.replace(slot) }
      assert_equal slot.to_bytes, core.root_cursor.slot.to_bytes
    end
    assert old.slot.empty?
  end

  def test_bytes_preserve_zero_bytes_and_unknown_tags
    core = Core::Database.memory(hash_id: "what", hash_size: 7)
    [["", nil, :short_bytes], ["12345678", nil, :short_bytes],
     ["123456", "\xff\0".b, :short_bytes], ["1234567", "xy", :bytes],
     ["a\0b", nil, :bytes], ["long string", nil, :bytes]].each do |data, tag, kind|
      core.transaction { |cursor| cursor.replace(core.bytes(data, format_tag: tag)) }
      slot = core.root_cursor.slot
      assert_equal kind, slot.tag
      value = core.read_bytes(slot)
      assert_equal data.b, value.bytes
      tag ? assert_equal(tag, value.format_tag) : assert_nil(value.format_tag)
      assert value.frozen?
      assert value.bytes.frozen?
    end
  end

  def test_early_exits_abort_and_next_commits
    core = Core::Database.memory
    core.transaction { |cursor| cursor.replace(Core::Slot.uint(1)); break }
    catch(:abort) { core.transaction { |cursor| cursor.replace(Core::Slot.uint(2)); throw :abort } }
    nonlocal_return(core)
    assert_raises(Interrupt) { core.transaction { |cursor| cursor.replace(Core::Slot.uint(4)); raise Interrupt } }
    assert core.root_cursor.slot.empty?
    assert_equal 62, core.committed_size
    core.transaction { |cursor| cursor.replace(Core::Slot.uint(5)); next :ignored }
    assert_equal 5, core.root_cursor.slot.value
  end

  def test_publication_faults_classify_durability_and_never_retry
    %i[append data_sync header_write header_sync].each do |point|
      store = FaultStore.new(Core::MemoryStore.new)
      core = Core::Database.new(store: store)
      syncs = 0
      store.fault = lambda do |name, args|
        syncs += 1 if name == :sync
        fail_here = (point == :append && name == :append) ||
                    (point == :data_sync && name == :sync && syncs == 1) ||
                    (point == :header_write && name == :write_at && args[0] == 20) ||
                    (point == :header_sync && name == :sync && syncs == 2)
        raise IOError, point.to_s if fail_here
      end
      calls = 0
      error = assert_raises(XitDB::CommitError) do
        core.transaction { |cursor| calls += 1; cursor.replace(Core::Slot.uint(42)) }
      end
      assert_equal 1, calls
      uncertain = %i[header_write header_sync].include?(point)
      assert_equal(uncertain ? :unknown : :not_committed, error.outcome)
      assert_instance_of IOError, error.cause
      store.fault = nil
      if uncertain
        assert core.needs_reopen?
        assert_raises(XitDB::TransactionStateError) { core.transaction { flunk "must not run" } }
      else
        assert core.root_cursor.slot.empty?
        assert_equal 62, store.length
        core.transaction { |cursor| cursor.replace(Core::Slot.uint(7)) }
        assert_equal 7, core.root_cursor.slot.value
      end
    end
  end

  def test_file_reopen_refresh_tail_discard_and_readonly
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.xit")
      first = Core::Database.open(path, file_id: 9)
      second = Core::Database.open(path)
      first.transaction { |cursor| cursor.replace(Core::Slot.uint(1)) }
      File.open(path, "ab") { |file| file.write("uncommitted") }
      second.transaction do |cursor|
        assert_equal 1, cursor.slot.value
        cursor.replace(Core::Slot.uint(2))
      end
      assert_equal 112, second.committed_size
      assert_equal 112, File.size(path)
      first.close
      second.close
      Core::Database.open(path, readonly: true) do |reader|
        assert_equal 2, reader.root_cursor.slot.value
        assert_raises(XitDB::ReadOnlyError) { reader.transaction { flunk "must not run" } }
      end
    end
  end

  def test_corruption_is_rejected_without_changing_input
    store = Core::MemoryStore.new
    Core::Database.new(store: store, file_id: 1)
    original = store.read_at(0, store.length)
    bad_crc = original.dup
    bad_crc.setbyte(61, bad_crc.getbyte(61) ^ 1)
    [original.byteslice(0, 61), bad_crc, original.byteslice(0, 19)].each do |bytes|
      bad = Core::MemoryStore.new(bytes)
      assert_raises(XitDB::CorruptionError) { Core::Database.new(store: bad) }
      assert_equal bytes, bad.read_at(0, bad.length)
    end
  end

  def test_byte_lengths_are_checked_against_snapshot_bound
    core = Core::Database.memory
    old = core.root_cursor
    core.transaction { |cursor| cursor.replace(core.bytes("long string")) }
    slot = core.root_cursor.slot
    assert_raises(XitDB::CorruptionError) { core.read_bytes(slot, bound: old.bound) }
    assert_raises(XitDB::CorruptionError) { core.read_bytes(Core::Slot.new(tag: :bytes, value: (1 << 64) - 1)) }
  end

  def test_transaction_ownership_checkpoint_freeze_and_cancel
    core = Core::Database.memory
    owned = nil
    core.transaction do |root|
      owned = root
      tx = root.transaction
      root.replace(Core::Slot.uint(1))
      detached = tx.cursor(slot: Core::Slot.uint(2))
      checkpoint = tx.checkpoint
      root.replace(Core::Slot.uint(3))
      detached.replace(Core::Slot.uint(4))
      temporary = tx.cursor(slot: core.bytes("temporary external bytes"))
      tx.restore(checkpoint)
      assert_equal 1, root.slot.value
      assert_equal 2, detached.slot.value
      assert_raises(XitDB::ExpiredViewError) { temporary.slot }
      assert_equal 62, tx.freeze
      error = Thread.new { root.slot rescue $! }.value
      assert_instance_of XitDB::TransactionStateError, error
      assert_raises(XitDB::TransactionStateError) { core.transaction {} }
    end
    assert_raises(XitDB::ExpiredViewError) { owned.slot }
    before = core.committed_size
    core.transaction { |root| root.transaction.cancel_publication }
    assert_equal before, core.committed_size
    assert_raises(XitDB::ReadOnlyError) { core.root_cursor.replace(Core::Slot.uint(5)) }
    core.close
    assert_raises(XitDB::ClosedError) { core.root_cursor }
  end

  def test_trailer_not_cached_header_supplies_root_and_initial_id_is_zero
    store = Core::MemoryStore.new
    core = Core::Database.new(store: store, file_id: 1)
    assert_equal "0000000000000000", store.read_at(46, 8).unpack1("H*")
    store.write_at(20, Core::Slot.uint(99).to_bytes)
    assert core.root_cursor.slot.empty?
    core.transaction { |cursor| cursor.replace(Core::Slot.uint(42)) }
    assert_equal 42, Core::Database.new(store: store).root_cursor.slot.value
  end

  def test_empty_database_matches_independent_go_fixture
    store = Core::MemoryStore.new
    Core::Database.new(store: store, file_id: 1)
    expected = File.read(File.expand_path("../fixtures/core/empty-v1.hex", __dir__)).strip
    assert_equal expected, store.read_at(0, store.length).unpack1("H*")
  end

  def test_cleanup_failure_preserves_caller_error_and_requires_reopen
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    original = Interrupt.new("application interrupt")
    store.fault = ->(name, _args) { raise IOError, "truncate failed" if name == :truncate }
    assert_same original, assert_raises(Interrupt) { core.transaction { raise original } }
    assert core.needs_reopen?
  end

  def test_cancelled_publication_reports_cleanup_failure
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    store.fault = ->(name, _args) { raise IOError, "truncate failed" if name == :truncate }
    error = assert_raises(XitDB::CommitError) do
      core.transaction { |cursor| cursor.transaction.cancel_publication }
    end
    assert_equal :not_committed, error.outcome
    assert core.needs_reopen?
  end

  def test_failure_after_header_sync_is_committed
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    store.release_fault = -> { raise IOError, "unlock failed" }
    error = assert_raises(XitDB::CommitError) { core.transaction { |cursor| cursor.replace(Core::Slot.uint(9)) } }
    assert_equal :committed, error.outcome
    assert_equal 9, core.root_cursor.slot.value
    assert core.needs_reopen?
  end

  def test_interrupt_during_publication_is_unknown_after_header_attempt
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    store.fault = ->(name, args) { raise Interrupt if name == :write_at && args.first == 20 }
    error = assert_raises(XitDB::CommitError) { core.transaction { |cursor| cursor.replace(Core::Slot.uint(9)) } }
    assert_equal :unknown, error.outcome
    assert_instance_of Interrupt, error.cause
  end

  def test_checkpoint_discards_later_checkpoints_even_after_reallocation
    core = Core::Database.memory
    core.transaction do |root|
      tx = root.transaction
      first = tx.checkpoint
      root.replace(core.bytes("123456789"))
      stale = tx.checkpoint
      tx.restore(first)
      root.replace(core.bytes("abcdefghi"))
      assert_raises(XitDB::TransactionStateError) { tx.restore(stale) }
      assert_equal "abcdefghi", root.read_bytes.bytes
    end
  end

  def test_freeze_protects_allocated_bytes_and_snapshot_reads
    core = Core::Database.memory
    core.transaction do |root|
      tx = root.transaction
      offset = tx.append("1234")
      tx.write_at(offset, "abcd")
      assert_equal "abcd", tx.read_at(offset, 4)
      tx.freeze
      assert_raises(XitDB::TransactionStateError) { tx.write_at(offset, "xxxx") }
      root.replace(core.bytes("captured bytes"))
    end
    old = core.root_cursor
    core.transaction { |root| root.replace(core.bytes("replacement bytes")) }
    assert_equal "captured bytes", old.read_bytes.bytes
  end

  def test_external_length_is_validated_before_reading_payload
    store = Core::MemoryStore.new
    core = Core::Database.new(store: store)
    core.transaction do |root|
      offset = root.transaction.append([0xffffffffffffffff].pack("Q>"))
      root.replace(Core::Slot.new(tag: :bytes, value: offset))
    end
    assert_raises(XitDB::CorruptionError) { core.root_cursor.read_bytes }
  end

  def test_partial_file_writes_and_sync_failures_reopen_at_observed_root
    %i[trailer data_sync header header_sync].each do |point|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "fault.xit")
        real = Core::FileStore.open(path)
        store = FaultStore.new(real)
        core = Core::Database.new(store: store)
        syncs = 0
        store.fault = lambda do |name, args|
          syncs += 1 if name == :sync
          if point == :trailer && name == :append
            real.append(args.first.byteslice(0, 10))
            raise IOError, "partial trailer"
          elsif point == :header && name == :write_at && args.first == 20
            real.write_at(20, args.last.byteslice(0, 9))
            real.flush
            raise IOError, "partial root header"
          elsif (point == :data_sync && name == :sync && syncs == 1) ||
                (point == :header_sync && name == :sync && syncs == 2)
            real.flush
            raise IOError, "sync failed"
          end
        end
        error = assert_raises(XitDB::CommitError) do
          core.transaction { |root| root.replace(Core::Slot.uint(42)) }
        end
        assert_equal(%i[header header_sync].include?(point) ? :unknown : :not_committed, error.outcome)
        store.fault = nil
        core.close
        Core::Database.open(path) do |reopened|
          if point == :header_sync
            assert_equal 42, reopened.root_cursor.slot.value
          else
            assert reopened.root_cursor.slot.empty?
          end
          reopened.transaction { |root| root.replace(Core::Slot.uint(7)) }
          assert_equal reopened.committed_size, File.size(path)
          assert_equal 7, reopened.root_cursor.slot.value
        end
      ensure
        core&.close
      end
    end
  end

  def test_unknown_hash_profile_reopens_and_mismatch_preserves_file
    store = Core::MemoryStore.new
    Core::Database.new(store: store, hash_id: "????", hash_size: 7, file_id: 55)
    original = store.read_at(0, store.length)
    core = Core::Database.new(store: store)
    assert_equal "????", core.header.hash_id
    assert_equal 7, core.header.hash_size
    assert_raises(XitDB::ProfileMismatchError) { Core::Database.new(store: store, hash_size: 20) }
    assert_equal original, store.read_at(0, store.length)
  end

  def test_application_io_failure_is_not_a_commit_failure
    core = Core::Database.memory
    original = IOError.new("application I/O")
    calls = 0
    error = assert_raises(IOError) do
      core.transaction do |root|
        calls += 1
        root.replace(core.bytes("allocated before abort"))
        raise original
      end
    end
    assert_same original, error
    assert_equal 1, calls
    assert_equal 62, core.committed_size
  end

  def test_release_failure_does_not_replace_application_exception
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    original = RuntimeError.new("application failure")
    store.release_fault = -> { raise IOError, "release failure" }
    error = assert_raises(RuntimeError) { core.transaction { raise original } }
    assert_same original, error
    assert core.needs_reopen?
  end

  def test_release_failure_preserves_throw_break_and_nonlocal_return
    %i[memory file].each do |kind|
      %i[throw break return].each do |exit_kind|
        Dir.mktmpdir do |dir|
          real = kind == :memory ? Core::MemoryStore.new : Core::FileStore.open(File.join(dir, "test.xit"))
          store = FaultStore.new(real)
          core = Core::Database.new(store: store)
          store.release_fault = -> { raise IOError, "release failed" }
          result = case exit_kind
          when :throw
            catch(:abort) { core.transaction { throw :abort, :original_exit } }
          when :break
            core.transaction { break :original_exit }
          when :return
            return_from_transaction(core)
          end
          assert_equal :original_exit, result
          assert core.needs_reopen?
          assert_equal 62, core.committed_size
          assert_raises(XitDB::TransactionStateError) { core.transaction { flunk "must not run" } }
        ensure
          store.release_fault = nil if store
          core&.close
        end
      end
    end
  end

  def test_temporary_cursors_are_reclaimed_during_transaction
    Core::Database.memory.transaction do |root|
      references = Array.new(200) { temporary_cursor_reference(root.transaction) }
      GC.start
      assert_equal 0, references.count(&:weakref_alive?)
      assert root.slot.empty?
    end
  end

  def test_released_checkpoints_do_not_retain_completed_operations
    Core::Database.memory.transaction do |root|
      tx = root.transaction
      references = Array.new(200) do
        checkpoint, reference = checkpoint_with_temporary_cursor(tx)
        tx.release_checkpoint(checkpoint)
        assert_raises(XitDB::TransactionStateError) { tx.restore(checkpoint) }
        [WeakRef.new(checkpoint), reference]
      end
      GC.start
      assert_equal 0, references.sum { |pair| pair.count(&:weakref_alive?) }
    end
  end

  def test_restore_releases_snapshot_ownership_and_preserves_live_cursors
    checkpoint, reference = Thread.new do
      retained = nil
      Core::Database.memory.transaction do |root|
        tx = root.transaction
        live = tx.cursor(slot: Core::Slot.uint(7))
        checkpoint, reference = checkpoint_with_temporary_cursor(tx)
        live.replace(Core::Slot.uint(8))
        GC.start
        assert reference.weakref_alive?
        tx.restore(checkpoint)
        assert_equal 7, live.slot.value
        assert_equal 0, checkpoint.slots.size, "consumed checkpoint still owns cursor states during the transaction"
        assert_raises(XitDB::TransactionStateError) { tx.restore(checkpoint) }
        retained = [checkpoint, reference]
      end
      retained
    end.value
    GC.start
    refute reference.weakref_alive?, "consumed checkpoint #{checkpoint.object_id} retained a cursor"
  end

  def test_expiration_releases_snapshots_even_when_an_expired_cursor_is_retained
    expired = checkpoint = reference = nil
    Core::Database.memory.transaction do |root|
      expired = root
      checkpoint, reference = checkpoint_with_temporary_cursor(root.transaction)
    end
    GC.start
    assert_raises(XitDB::ExpiredViewError) { expired.slot }
    refute reference.weakref_alive?
    assert checkpoint
  end

  def test_live_replaced_slots_survive_gc_and_checkpoint_release
    Core::Database.memory.transaction do |root|
      tx = root.transaction
      cursor = tx.cursor(slot: Core::Slot.uint(1))
      checkpoint = tx.checkpoint
      cursor.replace(Core::Slot.uint(42))
      tx.release_checkpoint(checkpoint)
      GC.start
      assert_equal 42, cursor.slot.value
    end
  end

  private

  def temporary_cursor_reference(transaction)
    WeakRef.new(transaction.cursor(slot: Core::Slot.uint(1)))
  end

  def checkpoint_with_temporary_cursor(transaction)
    cursor = transaction.cursor(slot: Core::Slot.uint(2))
    [transaction.checkpoint, WeakRef.new(cursor)]
  end

  def return_from_transaction(core)
    core.transaction { return :original_exit }
  end

  def nonlocal_return(core)
    core.transaction { |cursor| cursor.replace(Core::Slot.uint(3)); return }
  end
end
