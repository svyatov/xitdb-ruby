# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "timeout"

class StoreTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("xitdb-store")
    @path = File.join(@directory, "data.xit")
    @stores = []
  end

  def teardown
    @stores.each { |store| store.close unless store.closed? }
    FileUtils.remove_entry(@directory)
  end

  def test_exclusive_creation_and_existing_only_open_preserve_file_identity
    assert_raises(Errno::ENOENT) { file_store(create: false) }
    refute File.exist?(@path)
    created = file_store(exclusive: true)
    created.write_at(0, "kept")
    created.sync
    assert_raises(Errno::EEXIST) { file_store(exclusive: true) }
    existing = file_store(create: false)
    assert_equal "kept", existing.read_at(0, 4)
    assert_raises(ArgumentError) { file_store(create: false, exclusive: true) }
    assert_raises(ArgumentError) { file_store(readonly: true, exclusive: true) }
    assert_equal "kept", File.binread(@path)
  end

  # Catches shared-position reads, incorrect append offsets, and oversized buffering.
  def test_positional_reads_and_bounded_pending_writes
    each_store do |store|
      store.write_at(0, "abcdef")
      assert_equal "cd", store.read_at(2, 2)
      assert_equal 6, store.append("gh")
      assert_equal "abcdefgh", store.read_at(0, 8)
      assert_equal 8, store.length
    end

    store = file_store(buffer_limit: 8)
    store.write_at(0, "a" * 8)
    assert_equal 0, File.size(@path)
    store.append("b")
    assert_equal 8, File.size(@path)
    assert_equal "aaaaaaaab", store.read_at(0, 9)
  end

  # Catches character indexing, retained caller strings, and short reads at EOF.
  def test_binary_ownership_and_exact_reads
    each_store do |store|
      source = +"é\xff".b
      store.write_at(0, source)
      source.clear
      assert_equal "\xa9\xff".b, store.read_at(1, 2)
      assert_equal Encoding::BINARY, store.read_at(0, 3).encoding
      read = store.read_at(0, 3)
      read.clear
      assert_equal "\xc3\xa9\xff".b, store.read_at(0, 3)
      assert_equal "".b, store.read_at(100, 0)
      assert_raises(EOFError) { store.read_at(2, 2) }
      assert_raises(EOFError) { store.read_at(4, 1) }
    end

    initial = +"abc"
    store = XitDB::Core::MemoryStore.new(initial)
    @stores << store
    initial.clear
    assert_equal "abc", store.read_at(0, 3)
  end

  # Catches stale buffered overwrites and reads that omit either disk segment.
  def test_reads_span_disk_and_pending_window
    store = file_store(buffer_limit: 4)
    store.write_at(0, "abcdefghij")
    store.write_at(3, "XY")
    assert_equal "abcXYfghij", store.read_at(0, 10)
    assert_equal "cXYf", store.read_at(2, 4)
    store.write_at(0, "0123456789")
    store.flush
    assert_equal "0123456789", File.binread(@path)
  end

  # Catches discarded prefixes, buffered rollback writes, and missing zero extension.
  def test_truncate_and_sparse_writes
    each_store do |store|
      store.write_at(3, "xy")
      assert_equal "\0\0\0xy".b, store.read_at(0, 5)
      store.truncate(4)
      assert_equal "\0\0\0x".b, store.read_at(0, 4)
      store.truncate(7)
      assert_equal "\0\0\0x\0\0\0".b, store.read_at(0, 7)
      store.truncate(0)
      assert_equal 0, store.append("z")
      assert_equal "z", store.read_at(0, 1)
    end

    store = file_store
    store.append("discard")
    fault_file(store, :pwrite) { |_original, *_args| raise Errno::ENOSPC }
    store.truncate(0)
    store.flush
    assert_equal 0, File.size(@path)
  end

  # Catches a missing flush before fsync or close, and writable readonly handles.
  def test_sync_close_and_readonly_guards
    store = file_store
    store.append("abc")
    fault_file(store, :fsync) do |original|
      assert_equal "abc", File.binread(@path)
      original.call
    end
    store.sync
    store.append("d")
    store.close
    store.close
    assert_equal "abcd", File.binread(@path)

    readonly = file_store(readonly: true)
    assert_predicate readonly, :readonly?
    assert_equal "abcd", readonly.read_at(0, 4)
    assert_raises(XitDB::ReadOnlyError) { readonly.write_at(0, "z") }
    assert_raises(XitDB::ReadOnlyError) { readonly.append("z") }
    assert_raises(XitDB::ReadOnlyError) { readonly.truncate(0) }
    assert_raises(XitDB::ReadOnlyError) { readonly.with_exclusive_lock(timeout: 0) {} }
    assert_equal "abcd", File.binread(@path)
    assert_raises(Errno::ENOENT) { XitDB::Core::FileStore.open(File.join(@directory, "missing"), readonly: true) }
  end

  # Catches forgotten open-state checks and Ruby's implicit numeric coercions.
  def test_invalid_arguments_and_closed_operations
    each_store do |store|
      refute_predicate store, :readonly?
      assert_raises(ArgumentError) { store.read_at(-1, 1) }
      assert_raises(ArgumentError) { store.read_at(0, -1) }
      assert_raises(ArgumentError) { store.write_at(-1, "") }
      assert_raises(ArgumentError) { store.truncate(-1) }
      assert_raises(TypeError) { store.read_at(0.0, 1) }
      assert_raises(TypeError) { store.read_at(0, "1") }
      assert_raises(TypeError) { store.write_at(0, :bytes) }
      assert_raises(TypeError) { store.append(nil) }
      assert_raises(TypeError) { store.truncate(1.0) }
      store.close
      assert_predicate store, :closed?
      assert_raises(XitDB::ClosedError) { store.read_at(0, 0) }
      assert_raises(XitDB::ClosedError) { store.write_at(0, "") }
      assert_raises(XitDB::ClosedError) { store.append("") }
      assert_raises(XitDB::ClosedError) { store.length }
      assert_raises(XitDB::ClosedError) { store.truncate(0) }
      assert_raises(XitDB::ClosedError) { store.flush }
      assert_raises(XitDB::ClosedError) { store.sync }
      assert_raises(XitDB::ClosedError) { store.with_exclusive_lock(timeout: 0) {} }
    end
    assert_raises(ArgumentError) { file_store(buffer_limit: 0) }
    assert_raises(TypeError) { file_store(buffer_limit: 1.0) }
  end

  # Catches unhandled EINTR, skipped short-write suffixes, and short-read truncation.
  def test_partial_and_interrupted_syscalls
    store = file_store(buffer_limit: 4)
    interrupted = false
    fault_file(store, :pwrite) do |original, bytes, offset|
      unless interrupted
        interrupted = true
        raise Errno::EINTR
      end
      original.call(bytes.byteslice(0, 2), offset)
    end
    store.write_at(0, "abcdef")
    interrupted = false
    fault_file(store, :pread) do |original, count, offset|
      unless interrupted
        interrupted = true
        raise Errno::EINTR
      end
      original.call([count, 2].min, offset)
    end
    assert_equal "abcdef", store.read_at(0, 6)
    assert_equal "abcdef", File.binread(@path)
  end

  # Catches clearing pending bytes after an unsuccessful or zero-length write.
  def test_flush_failures_retain_pending_bytes_for_retry
    store = file_store
    store.append("abcdef")
    failing = true
    fault_file(store, :pwrite) do |original, bytes, offset|
      if failing
        original.call(bytes.byteslice(0, 2), offset)
        raise Errno::ENOSPC
      end
      original.call(bytes, offset)
    end
    assert_raises(Errno::ENOSPC) { store.flush }
    assert_equal "abcdef", store.read_at(0, 6)
    failing = false
    store.flush
    assert_equal "abcdef", File.binread(@path)

    store.append("g")
    failing = true
    fault_file(store, :pwrite) do |original, bytes, offset|
      failing ? 0 : original.call(bytes, offset)
    end
    assert_raises(IOError) { store.flush }
    failing = false
    store.flush
    assert_equal "abcdefg", File.binread(@path)
  end

  # Catches a raised close error that nevertheless loses the writable handle.
  def test_failed_close_preserves_the_store_for_recovery
    store = file_store
    store.append("abc")
    failing = true
    fault_file(store, :pwrite) do |original, bytes, offset|
      raise Errno::ENOSPC if failing

      original.call(bytes, offset)
    end
    assert_raises(Errno::ENOSPC) { store.close }
    refute_predicate store, :closed?
    failing = false
    store.close
    assert_equal "abc", File.binread(@path)
  end

  # Catches a missing writer mutex while allowing snapshot reads during a write.
  def test_writer_blocks_serialize_without_blocking_reads
    each_store do |store|
      store.write_at(0, "abc")
      entered = Queue.new
      release = Queue.new
      writer = Thread.new { store.with_exclusive_lock { entered << true; release.pop } }
      Timeout.timeout(2) { entered.pop }
      assert_equal "abc", store.read_at(0, 3)
      ran = false
      assert_raises(XitDB::BusyError) { store.with_exclusive_lock(timeout: 0.02) { ran = true } }
      refute ran
      release << true
      writer.value
      assert_equal :result, store.with_exclusive_lock(timeout: 0) { :result }
      assert_raises(RuntimeError) { store.with_exclusive_lock { raise "abort" } }
      assert_equal :released, store.with_exclusive_lock(timeout: 0) { :released }
    ensure
      release << true if writer&.alive?
      writer&.join
    end
  end

  # Catches pathname-only or per-handle serialization when flock does not contend locally.
  def test_separate_handles_share_a_writer_mutex_by_inode
    first = file_store
    alias_path = File.join(@directory, "alias.xit")
    File.link(@path, alias_path)
    second = XitDB::Core::FileStore.open(alias_path)
    @stores << second
    # File locking differs between operating systems. Isolate the process mutex here.
    [first, second].each do |store|
      fault_file(store, :flock) { |_original, *_args| 0 }
    end
    first.with_exclusive_lock do
      assert_raises(XitDB::BusyError) { second.with_exclusive_lock(timeout: 0) { flunk "writer ran" } }
    end
    first.close
    assert_equal :released, second.with_exclusive_lock(timeout: 0) { :released }
  end

  # Catches a missing advisory lock across cooperating processes.
  def test_writer_lock_contends_with_another_process
    store = file_store
    ready_reader, ready_writer = IO.pipe
    release_reader, release_writer = IO.pipe
    child = fork do
      ready_reader.close
      release_writer.close
      File.open(@path, "r+b") do |file|
        file.flock(File::LOCK_EX)
        ready_writer.write("ready")
        ready_writer.close
        release_reader.read(1)
      end
      exit! 0
    end
    ready_writer.close
    release_reader.close
    assert_equal "ready", Timeout.timeout(2) { ready_reader.read }
    assert_raises(XitDB::BusyError) { store.with_exclusive_lock(timeout: 0.02) { flunk "writer ran" } }
    release_writer.write("x")
    release_writer.close
    Process.wait(child)
    child = nil
    assert_equal :acquired, store.with_exclusive_lock(timeout: 0) { :acquired }
  ensure
    [ready_reader, ready_writer, release_reader, release_writer].compact.each { |io| io.close unless io.closed? }
    Process.wait(child) if child
  end

  # Catches unsafe close during a writer block and locks retained by invalid arguments.
  def test_lock_state_and_close_wait_for_active_writer
    each_store do |store|
      store.with_exclusive_lock do
        assert_raises(XitDB::TransactionStateError) { store.close }
        assert_raises(XitDB::TransactionStateError) { store.with_exclusive_lock(timeout: 0) {} }
      end
      [-1, Float::INFINITY, Float::NAN].each do |timeout|
        assert_raises(ArgumentError) { store.with_exclusive_lock(timeout: timeout) {} }
      end
      assert_raises(TypeError) { store.with_exclusive_lock(timeout: "1") {} }
      assert_raises(TypeError) { store.with_exclusive_lock(timeout: Complex(1, 1)) {} }
      entered = Queue.new
      release = Queue.new
      writer = Thread.new do
        store.with_exclusive_lock do
          entered << true
          release.pop
          store.append("done")
        end
      end
      Timeout.timeout(2) { entered.pop }
      closing = Queue.new
      closer = Thread.new { closing << true; store.close }
      Timeout.timeout(2) { closing.pop }
      refute_predicate store, :closed?
      release << true
      writer.value
      closer.value
      assert_predicate store, :closed?
    ensure
      release << true if writer&.alive?
      writer&.join
      closer&.join
    end
  end

  # Catches releasing an inode registry entry twice when two closers wait together.
  def test_concurrent_close_is_idempotent
    each_store do |store|
      entered = Queue.new
      release = Queue.new
      writer = Thread.new { store.with_exclusive_lock { entered << true; release.pop } }
      Timeout.timeout(2) { entered.pop }
      closers = Array.new(2) { Thread.new { store.close } }
      Timeout.timeout(2) { Thread.pass until closers.all? { |thread| thread.status == "sleep" } }
      release << true
      writer.value
      closers.each(&:value)
      assert_predicate store, :closed?
    ensure
      release << true if writer&.alive?
      writer&.join
      closers&.each(&:join)
    end
  end

  # Catches an incorrect default limit or buffering an individual oversized write.
  def test_default_buffer_limit_is_two_mebibytes
    store = file_store
    store.write_at(0, "a" * (2 * 1024 * 1024))
    assert_equal 0, File.size(@path)
    store.append("b")
    assert_equal 2 * 1024 * 1024, File.size(@path)
    store.truncate(0)
    store.write_at(0, "c" * (2 * 1024 * 1024 + 1))
    assert_equal 2 * 1024 * 1024 + 1, File.size(@path)
    assert_equal "cc", store.read_at(2 * 1024 * 1024 - 1, 2)
  end

  def test_unlock_failure_preserves_pending_exit_and_disables_writes
    store = file_store
    failure = IOError.new("unlock failed")
    fault_file(store, :flock) do |original, mode|
      raise failure if mode == File::LOCK_UN

      original.call(mode)
    end
    errors = []
    result = catch(:abort) do
      store.with_exclusive_lock(on_release_error: ->(error) { errors << error }) { throw :abort, :original }
    end
    assert_equal :original, result
    assert_equal [failure], errors
    assert_raises(XitDB::TransactionStateError) { store.append("must not write") }
    store.close
    file_store.with_exclusive_lock { assert true }
  end

  def test_unlock_failure_after_normal_return_remains_an_error
    store = file_store
    fault_file(store, :flock) do |original, mode|
      raise IOError, "unlock failed" if mode == File::LOCK_UN

      original.call(mode)
    end
    assert_raises(IOError) { store.with_exclusive_lock { :finished } }
    assert_raises(XitDB::TransactionStateError) { store.with_exclusive_lock { flunk "must not run" } }
  end

  def test_waiting_writer_cannot_enter_after_release_failure
    store = XitDB::Core::MemoryStore.new
    @stores << store
    entered = Queue.new
    waiting = Queue.new
    finish = Queue.new
    original_lock = store.method(:lock_writer)
    original_unlock = store.method(:unlock_writer)
    store.define_singleton_method(:lock_writer) do |deadline|
      waiting << true if Thread.current[:waiting_writer]
      original_lock.call(deadline)
    end
    store.define_singleton_method(:unlock_writer) do
      original_unlock.call
      raise IOError, "release failed" unless Thread.current[:waiting_writer]
    end
    first = Thread.new do
      store.with_exclusive_lock { entered << true; finish.pop }
    rescue IOError => error
      error
    end
    entered.pop
    second = Thread.new do
      Thread.current[:waiting_writer] = true
      store.with_exclusive_lock { :incorrectly_entered }
    rescue XitDB::TransactionStateError => error
      error
    end
    waiting.pop
    finish << true
    assert_instance_of IOError, first.value
    assert_instance_of XitDB::TransactionStateError, second.value
  ensure
    first&.join
    second&.join
  end

  private

  def each_store
    memory = XitDB::Core::MemoryStore.new
    @stores << memory
    yield memory
    yield file_store
  end

  def file_store(**options)
    store = XitDB::Core::FileStore.open(@path, **options)
    @stores << store
    store
  end

  def fault_file(store, method, &fault)
    file = store.instance_variable_get(:@file)
    original = file.method(method)
    file.singleton_class.remove_method(method) if file.singleton_methods.include?(method)
    file.define_singleton_method(method) { |*args| fault.call(original, *args) }
  end
end
