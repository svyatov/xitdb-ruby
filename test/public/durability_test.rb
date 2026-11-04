# frozen_string_literal: true

require "test_helper"
require "support/fault_store"
require "tmpdir"
require "timeout"

class PublicDurabilityTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "database.xit")
    @real = XitDB::Core::FileStore.open(@path)
    @store = FaultStore.new(@real)
    core = XitDB::Core::Database.new(store: @store)
    @database = XitDB::Database.new(core: core, profile: XitDB::Profiles::Portable.new)
    @database.transaction { |root| root["counter"] = 0 }
  end

  def teardown
    @store.fault = nil
    @store.release_fault = nil
    @database.close unless @database.closed?
    FileUtils.remove_entry(@directory)
  end

  def test_data_sync_failure_is_a_known_abort_and_allows_a_later_write
    fault = fail_sync(1)
    invocations = 0
    error = assert_raises(XitDB::CommitError) do
      @database.transaction { |root| invocations += 1; root["counter"] = 1 }
    end
    assert_equal :not_committed, error.outcome
    assert_same fault, error.cause
    assert_equal 1, invocations
    refute @database.core.needs_reopen?
    assert_equal 0, @database.snapshot["counter"]
    assert_equal 1, @database.history.size
    assert_equal 2, @database.transaction { |root| root["counter"] = 2 }["counter"]
    assert_reopened_counter(2)
  end

  def test_header_sync_failure_is_unknown_and_never_retries_the_callback
    fault = fail_sync(2)
    invocations = 0
    error = assert_raises(XitDB::CommitError) do
      @database.transaction { |root| invocations += 1; root["counter"] = 1 }
    end
    assert_equal :unknown, error.outcome
    assert_same fault, error.cause
    assert_equal 1, invocations
    assert @database.core.needs_reopen?
    assert_raises(XitDB::TransactionStateError) { @database.transaction { flunk "uncertain handle entered callback" } }
    # Visibility after failed fsync does not establish durability.
    assert_equal 1, @database.snapshot["counter"]
    @database.close
    assert_reopened_counter(1)
  end

  def test_partial_header_publication_is_unknown_and_reopens_at_previous_trailer
    @store.fault = lambda do |name, args|
      if name == :write_at && args.first == 20
        @real.write_at(20, args.last.byteslice(0, 9))
        @real.flush
        raise IOError, "partial root header"
      end
    end
    error = assert_raises(XitDB::CommitError) do
      @database.transaction { |root| root["counter"] = 1 }
    end
    assert_equal :unknown, error.outcome
    assert @database.core.needs_reopen?
    @store.fault = nil
    @database.close
    reopened = XitDB.open(@path)
    assert_equal 0, reopened.snapshot["counter"]
    reopened.transaction { |root| root["counter"] = 2 }
    assert_equal reopened.core.committed_size, File.size(@path)
  ensure
    reopened&.close
  end

  def test_unlock_failure_after_header_sync_is_committed
    fault = IOError.new("unlock failed")
    @store.release_fault = -> { raise fault }
    invocations = 0
    error = assert_raises(XitDB::CommitError) do
      @database.transaction { |root| invocations += 1; root["counter"] = 1 }
    end
    assert_equal :committed, error.outcome
    assert_same fault, error.cause
    assert_equal 1, invocations
    assert @database.core.needs_reopen?
    assert_raises(XitDB::TransactionStateError) { @database.transaction { flunk "failed handle entered callback" } }
    @store.release_fault = nil
    @database.close
    assert_reopened_counter(1)
  end

  def test_callback_error_keeps_identity_and_releases_the_writer
    failure = RuntimeError.new("application failed")
    error = assert_raises(RuntimeError) do
      @database.transaction do |root|
        root["counter"] = 1
        raise failure
      end
    end
    assert_same failure, error
    assert_equal 0, @database.snapshot["counter"]
    assert_equal 2, @database.transaction { |root| root["counter"] = 2 }["counter"]
  end

  def test_process_interruption_after_data_sync_keeps_previous_commit
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      database = XitDB.open(@path)
      store = database.core.instance_variable_get(:@store)
      file = store.instance_variable_get(:@file)
      sync = file.method(:fsync)
      file.define_singleton_method(:fsync) do
        sync.call
        writer.write("s")
        sleep
      end
      database.transaction { |root| root["counter"] = 1 }
      exit! 2
    end
    writer.close
    assert_equal "s", Timeout.timeout(5) { reader.read(1) }
    Process.kill("KILL", pid)
    _, status = Timeout.timeout(5) { Process.wait2(pid) }
    pid = nil
    assert status.signaled?
    XitDB.open(@path) do |reopened|
      assert_equal 0, reopened.snapshot["counter"]
      assert_equal 1, reopened.history.size
      reopened.transaction { |root| root["counter"] = 2 }
      assert_equal 2, reopened.snapshot["counter"]
      assert_equal reopened.core.committed_size, File.size(@path)
    end
  ensure
    if pid
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
    [reader, writer].compact.each { |io| io.close unless io.closed? }
  end

  private

  def fail_sync(number)
    file = @real.instance_variable_get(:@file)
    sync = file.method(:fsync)
    calls = 0
    failure = IOError.new("fsync failed")
    file.define_singleton_method(:fsync) do
      calls += 1
      raise failure if calls == number

      sync.call
    end
    failure
  end

  def assert_reopened_counter(expected)
    XitDB.open(@path) { |reopened| assert_equal expected, reopened.snapshot["counter"] }
  end
end
