# frozen_string_literal: true

# Regression tests for full and incremental replication, staging validation, and publication failures.

require "English"
require "test_helper"
require "stringio"
require "tmpdir"
require_relative "../support/fault_store"

# Covers full and incremental replication, staging validation, and publication failures.
# @api private
class ReplicationTest < Minitest::Test
  Core = XitDB::Core
  EMPTY = ["7869740000010014736861310000000000000001000000000000000000000000000000003e" \
           "0000000000000000000000000000000000d95e2cd540a1ea38"].pack("H*").freeze
  # Independent MSB-first CRC-64/XZ vectors, with distinct explicit commit IDs.
  FIRST = ["08000000000000000711223344556677885cc74b2820289d85"].pack("H*").freeze
  DIVERGED = ["0800000000000000078877665544332211bd45d60798aeec1e"].pack("H*").freeze
  SECOND = ["080000000000000008123456789abcdef02f0a1a87b732917d"].pack("H*").freeze

  # Checks that incremental replication resumes matching history and detects divergent commits.
  def test_incremental_replication_and_diverged_history
    source = database(image(FIRST, SECOND))
    replica = database(EMPTY)
    diverged = database(image(DIVERGED))
    state = replica.replica_state

    assert_predicate state, :frozen?
    assert_equal 62, state.committed_size
    assert_equal 0xd95e2cd540a1ea38, state.checksum
    assert_equal 62, source.replication_start(state)
    assert_equal 0, source.replication_start(diverged.replica_state)
    stream = StringIO.new("".b)
    source.read_committed(62, 112, stream)

    assert_equal FIRST + SECOND, stream.string
    replica.apply_replicated(62, StringIO.new(stream.string), 50)

    assert_equal source.committed_size, replica.committed_size
    assert_equal 0x2f0a1a87b732917d, replica.replica_state.checksum
    assert_equal 8, replica.root_cursor.slot.value
    assert_equal 112, source.replication_start(replica.replica_state)
    assert_equal 0, diverged.replication_start(replica.replica_state)
    assert_equal 0, source.replication_start(Core::Database.memory(file_id: 2).replica_state)
  end

  # Checks historical full exports rewrite header and accept partial writes.
  def test_historical_full_exports_rewrite_header_and_accept_partial_writes
    source = database(image(FIRST, SECOND))
    output = StringIO.new("".b)
    output.define_singleton_method(:write) { |bytes| super(bytes.byteslice(0, 3)) }
    source.read_committed(0, 87, output)

    assert_equal image(FIRST), output.string
    assert_equal 7, database(output.string).root_cursor.slot.value
    empty = StringIO.new("".b)
    source.read_committed(0, 62, empty)

    assert_equal EMPTY, empty.string
  end

  # Checks invalid ranges and in place replacement leave committed bytes unchanged.
  def test_invalid_ranges_and_in_place_replacement_leave_committed_bytes_unchanged
    store = Core::MemoryStore.new(image(FIRST))
    db = Core::Database.new(store: store)

    [[-1, 87], [1, 87], [88, 87], [0, 88], [0, 86]].each do |start, finish|
      assert_raises(ArgumentError, XitDB::CorruptionError) { db.read_committed(start, finish, StringIO.new) }
    end
    assert_raises(TypeError) { db.read_committed(0, "87", StringIO.new) }
    [[0, 87], [62, 25], [87, -1]].each do |start, length|
      assert_raises(ArgumentError) { db.apply_replicated(start, StringIO.new(image(FIRST)), length) }
    end
    db.apply_replicated(87, StringIO.new, 0)

    assert_equal image(FIRST), store.read_at(0, store.length)
  end

  # Checks interrupted append and wrong trailers preserve last good state.
  def test_interrupted_append_and_wrong_trailers_preserve_last_good_state
    Dir.mktmpdir do |dir|
      path = File.join(dir, "replica")
      File.binwrite(path, image(FIRST))
      Core::Database.open(path) do |replica|
        last_good_state = replica.replica_state
        bad = SECOND.dup
        bad.setbyte(24, bad.getbyte(24) ^ 1)
        [[SECOND.byteslice(0, 20), 25, EOFError], [bad, 25, XitDB::CorruptionError],
         [SECOND, 24, XitDB::CorruptionError], [SECOND, 26, EOFError],
         [DIVERGED, 25, XitDB::CorruptionError]].each do |bytes, length, error|
          assert_raises(error) { replica.apply_replicated(87, StringIO.new(bytes), length) }
          assert_equal last_good_state, replica.replica_state
          assert_equal image(FIRST), File.binread(path)
          refute_predicate replica, :needs_reopen?
        end
        input = StringIO.new("#{SECOND}next frame")
        input.define_singleton_method(:read) { |length| super([length, 2].min) }
        replica.apply_replicated(87, input, 25)

        assert_equal 25, input.pos
        assert_equal image(FIRST, SECOND), File.binread(path)
      end
    end
  end

  # Checks that staged full copy validates image and preserves existing targets.
  def test_staged_full_copy_validates_image_and_preserves_existing_targets
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stage")
      input = StringIO.new(image(FIRST))
      copy = Core::Database.copy_replica(to: path, source_io: input, length: 87)

      assert_equal 7, copy.root_cursor.slot.value
      assert_equal image(FIRST), File.binread(path)
      refute_predicate input, :closed?
      copy.close
      assert_raises(ArgumentError) { Core::Database.copy_replica(to: path, source_io: StringIO.new(EMPTY), length: 62) }
      assert_equal image(FIRST), File.binread(path)
      empty_path = File.join(dir, "empty")
      File.binwrite(empty_path, "")
      Core::Database.copy_replica(to: empty_path, source_io: StringIO.new(EMPTY), length: 62).close

      assert_equal EMPTY, File.binread(empty_path)
      invalid = image(FIRST).dup
      invalid[29, 8] = [62].pack("Q>")
      [image(FIRST).byteslice(0, 80), invalid, "#{image(FIRST)}extra"].each_with_index do |bytes, i|
        failed = File.join(dir, "failed-#{i}")
        assert_raises(EOFError, XitDB::CorruptionError) do
          Core::Database.copy_replica(to: failed, source_io: StringIO.new(bytes), length: [87, bytes.bytesize].max)
        end
        assert_equal "", File.binread(failed)
      end
    end
  end

  # Checks staging rejects aliases and checks emptiness after locking.
  def test_staging_rejects_aliases_and_checks_emptiness_after_locking
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "source")
      File.binwrite(source_path, image(FIRST))
      hardlink = File.join(dir, "hardlink")
      symlink = File.join(dir, "symlink")
      File.link(source_path, hardlink)
      File.symlink(source_path, symlink)
      [source_path, hardlink, symlink].each do |target|
        input = File.open(source_path, "rb") # rubocop:disable Style/FileOpen -- The ensure block closes the descriptor after the assertion.
        assert_raises(ArgumentError) { Core::Database.copy_replica(to: target, source_io: input, length: 87) }
        assert_equal 0, input.pos
        assert_equal image(FIRST), File.binread(source_path)
      ensure
        input&.close
      end
      path = File.join(dir, "contended")
      captured = nil
      competing = image(FIRST)
      configure = lambda do |store|
        captured = store
        original = store.method(:with_exclusive_lock)
        store.define_singleton_method(:with_exclusive_lock) do |**options, &block|
          File.binwrite(path, competing)
          original.call(**options, &block)
        end
      end

      with_target_store(path, configure) do
        assert_raises(ArgumentError) { Core::Database.copy_replica(to: path, source_io: StringIO.new(EMPTY), length: 62) }
      end
      assert_predicate captured, :closed?
      assert_equal image(FIRST), File.binread(path)
    end
  end

  # Checks staging rejects malformed headers root slots and trailers.
  def test_staging_rejects_malformed_headers_root_slots_and_trailers
    corruptions = [
      ->(bytes) { bytes[0, 3] = "bad" },
      ->(bytes) { bytes[4, 2] = [2].pack("n") },
      ->(bytes) { bytes.setbyte(20, 9) },
      ->(bytes) { bytes.setbyte(86, bytes.getbyte(86) ^ 1) }
    ]
    Dir.mktmpdir do |dir|
      corruptions.each_with_index do |corrupt, index|
        path = File.join(dir, index.to_s)
        bytes = image(FIRST)
        corrupt.call(bytes)
        assert_raises(XitDB::CorruptionError, XitDB::FormatVersionError) do
          Core::Database.copy_replica(to: path, source_io: StringIO.new(bytes), length: bytes.bytesize)
        end
        assert_equal "", File.binread(path)
      end
    end
  end

  # Checks transport errors nonlocal exits and cleanup failure preserve the original error.
  def test_transport_errors_nonlocal_exits_and_cleanup_failure_preserve_the_original_error
    %i[error throw cleanup_failure].each do |point|
      store = FaultStore.new(Core::MemoryStore.new(image(FIRST)))
      db = Core::Database.new(store: store)
      state = db.replica_state
      original = IOError.new("transport failed")
      input = StringIO.new(SECOND)
      input.define_singleton_method(:read) do |length|
        if pos.positive?
          throw :stop if point == :throw
          raise original
        end
        super([length, 3].min)
      end
      if point == :cleanup_failure
        store.fault = ->(name, _args) { raise IOError, "cleanup failed" if name == :truncate }
      end
      if point == :throw
        catch(:stop) { db.apply_replicated(87, input, 25) }
      else
        assert_same original, assert_raises(IOError) { db.apply_replicated(87, input, 25) }
      end

      assert_equal state, db.replica_state
      assert_equal(point == :cleanup_failure, db.needs_reopen?)
      assert_equal(point == :cleanup_failure ? 90 : 87, store.length)
    ensure
      store&.close
    end
  end

  # Checks invalid transport progress is rejected without consuming another frame.
  def test_invalid_transport_progress_is_rejected_without_consuming_another_frame
    source = database(image(FIRST))
    [0, nil, -1, 1000].each do |progress|
      output = StringIO.new("".b)
      output.define_singleton_method(:write) { |_bytes| progress }
      assert_raises(IOError) { source.read_committed(0, 87, output) }
    end
    ["", nil, "a" * 26, 5].each do |chunk|
      replica = database(image(FIRST))
      input = StringIO.new(SECOND)
      input.define_singleton_method(:read) { |_length| chunk }
      assert_raises(EOFError, IOError) { replica.apply_replicated(87, input, 25) }
      assert_equal 87, replica.committed_size
      assert_equal 7, replica.root_cursor.slot.value
    end
    source.close
  end

  # Checks that file publication failures classify durability and recover.
  def test_file_publication_failures_classify_durability_and_recover
    outcomes = { append: :not_committed, data_sync: :not_committed, header_write: :unknown,
                 header_sync: :unknown, release: :committed }
    %i[append data_sync header_write header_sync release].each do |point|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "replica")
        File.binwrite(path, image(FIRST))
        store = FaultStore.new(Core::FileStore.open(path))
        replica = Core::Database.new(store: store)
        syncs = 0
        store.fault = lambda do |name, args|
          syncs += 1 if name == :sync
          fail_here = (point == :append && name == :append) ||
                      (point == :data_sync && name == :sync && syncs == 1) ||
                      (point == :header_write && name == :write_at && args.first == 20) ||
                      (point == :header_sync && name == :sync && syncs == 2)
          raise IOError, "injected #{point}" if fail_here
        end
        store.release_fault = -> { raise IOError, "release failed" } if point == :release
        error = assert_raises(XitDB::CommitError) { replica.apply_replicated(87, StringIO.new(SECOND), 25) }
        outcome = outcomes.fetch(point)

        assert_equal outcome, error.outcome
        assert_instance_of IOError, error.cause
        store.fault = nil
        store.release_fault = nil
        if outcome == :not_committed
          refute_predicate replica, :needs_reopen?
          assert_equal image(FIRST), File.binread(path)
          replica.apply_replicated(87, StringIO.new(SECOND), 25)
        else
          assert_predicate replica, :needs_reopen?
          assert_raises(XitDB::TransactionStateError) { replica.apply_replicated(112, StringIO.new, 0) }
          assert_raises(XitDB::TransactionStateError) { replica.transaction { nil } }
        end
        replica.close

        Core::Database.open(path, readonly: true) do |reopened|
          assert_equal(point == :header_write ? 7 : 8, reopened.root_cursor.slot.value)
        end
      ensure
        store&.close
      end
    end
  end

  # Checks that actual partial file write and sync failure preserve old commit.
  def test_actual_partial_file_write_and_sync_failure_preserve_old_commit
    Dir.mktmpdir do |dir|
      path = File.join(dir, "replica")
      File.binwrite(path, image(FIRST))
      store = Core::FileStore.open(path)
      db = Core::Database.new(store: store)
      file = store.instance_variable_get(:@file)
      original = file.method(:pwrite)
      calls = 0
      file.define_singleton_method(:pwrite) do |bytes, offset|
        calls += 1
        raise Errno::ENOSPC if calls == 2

        original.call(bytes.byteslice(0, 3), offset)
      end
      error = assert_raises(XitDB::CommitError) { db.apply_replicated(87, StringIO.new(SECOND), 25) }
      assert_equal :not_committed, error.outcome
      assert_instance_of Errno::ENOSPC, error.cause
      assert_equal image(FIRST), File.binread(path)
      db.apply_replicated(87, StringIO.new(SECOND), 25)

      assert_equal image(FIRST, SECOND), File.binread(path)
    ensure
      db&.close
    end
  end

  # Checks that staging interrupts and sync failures close the descriptor.
  def test_staging_interrupts_and_sync_failures_close_the_descriptor
    interrupted_points = %i[interrupt throw throw_in_rescue]
    Dir.mktmpdir do |dir|
      %i[interrupt throw throw_in_rescue data_write sync].each do |point|
        path = File.join(dir, point.to_s)
        captured = nil
        configure = lambda do |store|
          captured = store
          file = store.instance_variable_get(:@file)
          if point == :data_write
            original = store.method(:append)
            store.define_singleton_method(:append) do |bytes|
              original.call(bytes)
              raise IOError, "append failed"
            end
          elsif point == :sync
            file.define_singleton_method(:fsync) { raise IOError, "fsync failed" }
          end
        end
        input = StringIO.new(image(FIRST))
        if interrupted_points.include?(point)
          input.define_singleton_method(:read) do |length|
            if pos.positive?
              throw :stop unless point == :interrupt
              raise Interrupt, "transport interrupted"
            end
            super([length, 40].min)
          end
        end
        with_target_store(path, configure) do
          action = -> { Core::Database.copy_replica(to: path, source_io: input, length: 87) }
          case point
          when :throw
            catch(:stop) { action.call }
          when :throw_in_rescue
            begin
              raise "enclosing rescue"
            rescue RuntimeError
              catch(:stop) { action.call }
            end
          when :interrupt

            assert_raises(Interrupt, &action)
          else
            error = assert_raises(XitDB::CommitError, &action)
            assert_equal(point == :sync ? :unknown : :not_committed, error.outcome)
          end
        end

        assert_predicate captured, :closed?
        refute_predicate input, :closed?
        assert_equal(point == :sync ? image(FIRST) : "", File.binread(path))
      end
    end
  end

  # Checks staging persistent write failure closes descriptor and retains physical bytes.
  def test_staging_persistent_write_failure_closes_descriptor_and_retains_physical_bytes
    [false, true].product([0, 3]).each do |existing, prefix_length|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "stage")
        File.binwrite(path, "") if existing
        storage_error = Errno::ENOSPC.new("persistent staging write failure")
        captured = nil
        original_error = nil
        retained_bytes = nil
        configure = lambda do |store|
          captured = store
          file = store.instance_variable_get(:@file)
          write = file.method(:pwrite)
          attempts = 0
          file.define_singleton_method(:pwrite) do |bytes, offset|
            attempts += 1
            raise storage_error unless attempts == 1 && prefix_length.positive?

            write.call(bytes.byteslice(0, prefix_length), offset)
          end
          lock = store.method(:with_exclusive_lock)
          store.define_singleton_method(:with_exclusive_lock) do |**options, &block|
            lock.call(**options, &block)
          rescue XitDB::CommitError => e
            original_error = e
            retained_bytes = File.binread(path)
            raise
          end
        end
        input = StringIO.new(EMPTY)
        with_target_store(path, configure) do
          error = assert_raises(XitDB::CommitError) do
            Core::Database.copy_replica(to: path, source_io: input, length: 62)
          end
          assert_same original_error, error
          assert_same storage_error, error.cause
          assert_equal :unknown, error.outcome
        end
        assert_predicate captured.instance_variable_get(:@file), :closed?
        assert_predicate captured, :closed?
        assert_equal EMPTY.byteslice(0, prefix_length), retained_bytes
        assert_equal retained_bytes, File.binread(path)
        assert_equal 62, input.pos
        refute_predicate input, :closed?
      ensure
        captured&.close(discard: true)
      end
    end
  end

  # Checks staging transient write failure uses ordinary close to finish flushing.
  def test_staging_transient_write_failure_uses_ordinary_close_to_finish_flushing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stage")
      captured = nil
      storage_error = Errno::ENOSPC.new("transient staging write failure")
      configure = lambda do |store|
        captured = store
        file = store.instance_variable_get(:@file)
        write = file.method(:pwrite)
        attempts = 0
        file.define_singleton_method(:pwrite) do |bytes, offset|
          attempts += 1
          raise storage_error if attempts == 2

          write.call(attempts == 1 ? bytes.byteslice(0, 3) : bytes, offset)
        end
      end
      input = StringIO.new(EMPTY)
      with_target_store(path, configure) do
        error = assert_raises(XitDB::CommitError) do
          Core::Database.copy_replica(to: path, source_io: input, length: 62)
        end
        assert_same storage_error, error.cause
        assert_equal :unknown, error.outcome
      end
      assert_predicate captured.instance_variable_get(:@file), :closed?
      assert_predicate captured, :closed?
      assert_equal EMPTY, File.binread(path)
      Core::Database.open(path, readonly: true) { |db| assert_equal 62, db.committed_size }
      refute_predicate input, :closed?
    ensure
      captured&.close(discard: true)
    end
  end

  # Checks export is fixed during concurrent append and close waits.
  def test_export_is_fixed_during_concurrent_append_and_close_waits
    Dir.mktmpdir do |dir|
      path = File.join(dir, "source")
      File.binwrite(path, image(FIRST))
      source = Core::Database.open(path)
      entered = Queue.new
      release = Queue.new
      output = StringIO.new("".b)
      output.define_singleton_method(:write) do |bytes|
        if pos.zero?
          entered << true
          release.pop
        end
        super(bytes)
      end
      reader = Thread.new { source.read_committed(0, 87, output) }
      entered.pop
      source.transaction { |root| root.replace(Core::Slot.uint(9)) }

      assert_equal 112, source.committed_size
      closer = Thread.new { source.close }
      Thread.pass until closer.status == "sleep"

      refute_predicate source, :closed?
      release << true
      reader.value
      closer.value

      assert_predicate source, :closed?
      assert_equal image(FIRST), output.string
      assert_raises(XitDB::ClosedError) { source.replica_state }
      assert_raises(XitDB::ClosedError) { source.read_committed(0, 87, StringIO.new) }
    ensure
      release << true if reader&.alive?
      reader&.join
      closer&.join
      source&.close
    end
  end

  # Checks application refreshes under lock and preserves snapshots.
  def test_application_refreshes_under_lock_and_preserves_snapshots
    Dir.mktmpdir do |dir|
      path = File.join(dir, "replica")
      File.binwrite(path, image(FIRST))
      first = Core::Database.open(path)
      second = Core::Database.open(path, lock_timeout: 0.01)
      snapshot = second.root_cursor
      first.transaction do |_root|
        error = Thread.new do
          second.apply_replicated(87, StringIO.new(SECOND), 25)
        rescue StandardError
          $ERROR_INFO
        end.value

        assert_instance_of XitDB::BusyError, error
        assert_raises(XitDB::TransactionStateError) { first.apply_replicated(87, StringIO.new(SECOND), 25) }
      end
      input = StringIO.new(SECOND)
      assert_raises(ArgumentError) { second.apply_replicated(87, input, 25) }
      assert_equal 0, input.pos
      assert_equal 7, snapshot.slot.value
      Core::Database.open(path, readonly: true) do |readonly|
        assert_raises(XitDB::ReadOnlyError) { readonly.apply_replicated(112, input, 25) }
      end
    ensure
      first&.close
      second&.close
    end
  end

  # Checks opaque profile bytes bounded streaming and compaction generation.
  def test_opaque_profile_bytes_bounded_streaming_and_compaction_generation
    Dir.mktmpdir do |dir|
      source = Core::Database.memory(hash_id: "rb01", file_id: 1)
      payload = ("\x00\xffopaque".b * 30_000).freeze
      source.transaction { |root| root.replace(source.bytes(payload, format_tag: "\xff\x00".b)) }
      output = StringIO.new("".b)
      writes = []
      output.define_singleton_method(:write) do |bytes|
        writes << bytes.bytesize
        super(bytes)
      end
      source.read_committed(0, source.committed_size, output)

      assert_operator writes.max, :<=, 65_536
      output.rewind
      reads = []
      output.define_singleton_method(:read) do |length|
        reads << length
        super([length, 997].min)
      end
      copy = Core::Database.copy_replica(to: File.join(dir, "copy"), source_io: output, length: output.size)

      assert_operator reads.max, :<=, 65_536
      assert_equal "rb01", copy.header.hash_id
      assert_equal payload, copy.root_cursor.read_bytes.bytes
      assert_equal "\xff\x00".b, copy.root_cursor.read_bytes.format_tag
      assert_equal source.replica_state, copy.replica_state
      compacted = source.compact(to: File.join(dir, "compacted"))

      assert_equal 0, source.replication_start(compacted.replica_state)
      assert_equal payload, compacted.root_cursor.read_bytes.bytes
    ensure
      compacted&.close
      copy&.close
      source&.close
    end
  end

  private

  # Builds raw database bytes with supplied trailers and a matching cached root.
  # @param trailers [Array<String>] serialized trailers
  # @return [String] binary database image
  def image(*trailers)
    bytes = EMPTY + trailers.join
    bytes[20, 17] = trailers.last.byteslice(0, 9) + [bytes.bytesize].pack("Q>") unless trailers.empty?
    bytes
  end

  # Opens a raw memory database from deliberately constructed fixture bytes.
  # @param bytes [String] binary database image
  # @return [XitDB::Core::Database] database under test
  def database(bytes)
    Core::Database.new(store: Core::MemoryStore.new(bytes))
  end

  # Intercepts target-store opening to install the requested fault.
  # @param path [String] destination path to intercept
  # @param configure [Proc] callback that configures the target store
  # @yield executes the operation under test
  # @return [Object] block result
  def with_target_store(path, configure)
    original = Core::FileStore.method(:open)
    Core::FileStore.singleton_class.remove_method(:open)
    Core::FileStore.define_singleton_method(:open) do |target, **options|
      store = original.call(target, **options)
      configure.call(store) if target == path
      store
    end
    yield
  ensure
    Core::FileStore.singleton_class.remove_method(:open)
    Core::FileStore.define_singleton_method(:open, original)
  end
end
