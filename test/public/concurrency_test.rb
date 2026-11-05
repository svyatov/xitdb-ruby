# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "timeout"

class PublicConcurrencyTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "database.xit")
    @handles = []
    @threads = []
    @children = []
  end

  def teardown
    @threads.each { |thread| thread.kill if thread.alive? }
    # Kill all workers before joining any worker, so waiting cannot prevent cleanup.
    @threads.each do |thread| # rubocop:disable Style/CombinableLoops
      thread.join
    rescue StandardError
      nil
    end
    @children.each do |pid|
      begin
        Process.kill("KILL", pid)
      rescue StandardError
        Errno::ESRCH
      end
      begin
        Process.wait(pid)
      rescue StandardError
        Errno::ECHILD
      end
    end
    @handles.each { |handle| handle.close unless handle.closed? }
    FileUtils.remove_entry(@directory)
  end

  def test_two_handles_refresh_after_lock
    open_database.transaction { |root| root["counter"] = 0 }
    ready_read, ready_write = IO.pipe
    start_read, start_write = IO.pipe
    2.times do
      @children << fork do
        ready_read.close
        start_write.close
        XitDB.open(@path) do |database|
          ready_write.write("r")
          start_read.read(1)
          100.times do
            callback_invocations_on_success = 0
            database.transaction do |root|
              callback_invocations_on_success += 1
              root["counter"] += 1
            end
            exit! 2 unless callback_invocations_on_success == 1
          end
        end
        exit! 0
      end
    end
    ready_write.close
    start_read.close

    assert_equal "rr", Timeout.timeout(5) { ready_read.read(2) }
    start_write.write("ss")
    @children.dup.each do |pid|
      _, status = Timeout.timeout(10) { Process.wait2(pid) }
      @children.delete(pid)

      assert_predicate status, :success?, "writer exited with #{status.inspect}"
    end
    reopened = open_database

    assert_equal 200, reopened.snapshot["counter"]
  ensure
    [ready_read, ready_write, start_read, start_write].compact.each { |io| io.close unless io.closed? }
  end

  def test_lock_timeout_does_not_invoke_callback
    owner = open_database
    waiter = open_database(lock_timeout: 0.02)
    entered = Queue.new
    release = Queue.new
    writer = in_thread do
      owner.transaction do
        entered << true
        release.pop
      end
    end
    Timeout.timeout(2) { entered.pop }
    callback_invocations_on_lock_timeout = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(XitDB::BusyError) do
      waiter.transaction { callback_invocations_on_lock_timeout += 1 }
    end
    assert_equal 0, callback_invocations_on_lock_timeout
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    release << true
    join(writer)
    callback_invocations_on_success = 0
    waiter.transaction { callback_invocations_on_success += 1 }

    assert_equal 1, callback_invocations_on_success
  end

  def test_nested_handles_for_one_inode_reject_before_callback
    first = open_database
    alias_path = File.join(@directory, "alias.xit")
    File.link(@path, alias_path)
    second = open_database(path: alias_path, lock_timeout: 0)
    called = false
    first.transaction do |root|
      root["counter"] = 1
      assert_raises(XitDB::TransactionStateError) { second.transaction { called = true } }
    end
    refute called
    assert_equal 1, second.snapshot["counter"]
  end

  def test_snapshot_reads_do_not_wait_for_writer
    database = open_database
    database.transaction { |root| root["value"] = "old" * 100 }
    snapshot = database.snapshot
    entered = Queue.new
    release = Queue.new
    writer = in_thread do
      database.transaction do |root|
        root["value"] = "new" * 100
        entered << true
        release.pop
      end
    end
    Timeout.timeout(2) { entered.pop }

    assert_equal "old" * 100, Timeout.timeout(2) { snapshot["value"] }
    assert_equal "old" * 100, Timeout.timeout(2) { database.snapshot["value"] }
    release << true
    join(writer)

    assert_equal "new" * 100, database.snapshot["value"]
    assert_equal "old" * 100, snapshot["value"]
  end

  def test_close_waits_for_complete_public_read
    entered = Queue.new
    release = Queue.new
    reading_thread = nil
    hasher = XitDB::Core::Hasher.new(id: "test", size: 20) do |key|
      if Thread.current == reading_thread
        entered << true
        release.pop
      end
      Digest::SHA1.digest(key)
    end
    database = open_database(hash: hasher)
    database.transaction { |root| root["value"] = "stored" * 100 }
    snapshot = database.snapshot
    reader = in_thread do
      reading_thread = Thread.current
      snapshot["value"]
    end
    Timeout.timeout(2) { entered.pop }
    closer = in_thread { database.close }
    Timeout.timeout(2) { Thread.pass until closer.status == "sleep" || !closer.alive? }
    assert_raises(XitDB::ClosedError) { database.snapshot }
    assert_raises(XitDB::ClosedError) { database.transaction { flunk "closing handle entered callback" } }
    release << true

    assert_equal "stored" * 100, join(reader)
    join(closer)

    assert_predicate database, :closed?
    assert_raises(XitDB::ClosedError) { snapshot["value"] }
  end

  def test_close_waits_for_transaction_and_returned_snapshot_construction
    database = open_database
    entered = Queue.new
    release = Queue.new
    writer = in_thread do
      database.transaction do |root|
        root["counter"] = 1
        entered << true
        release.pop
      end
    end
    Timeout.timeout(2) { entered.pop }
    closer = in_thread { database.close }
    Timeout.timeout(2) { Thread.pass until closer.status == "sleep" || !closer.alive? }
    release << true

    assert_instance_of XitDB::Snapshot, join(writer)
    join(closer)

    assert_predicate database, :closed?
    assert_equal 1, open_database.snapshot["counter"]
  end

  def test_iteration_releases_read_guard_before_callback
    database = open_database
    database.transaction do |root|
      root["a"] = 1
      root["b"] = 2
    end
    snapshot = database.snapshot
    assert_raises(XitDB::ClosedError) do
      snapshot.each do |_key, _value|
        closer = in_thread { database.close }
        join(closer)
      end
    end
    assert_predicate database, :closed?
  end

  def test_logical_reads_finish_before_close
    operations = [
      ["array", ->(_db, view) { view[1] }, 2],
      ["array", ->(_db, view) { view[0, 2].class }, XitDB::Views::Slice],
      ["array", ->(_db, view) { view.fetch(1) }, 2],
      ["array", ->(_db, view) { view.first(2) }, [1, 2]],
      ["array", ->(_db, view) { view.last(2) }, [2, 3]],
      ["array", ->(_db, view) { view.each { |value| break value } }, 1], # rubocop:disable Lint/UnreachableLoop -- Exercise early iterator exit.
      ["linked", ->(_db, view) { view.split(1).size }, 2],
      ["set", ->(_db, view) { view.include?("a") }, true],
      ["sorted", ->(_db, view) { view.rank("b") }, 1],
      ["sorted", ->(_db, view) { view.keys }, %w[a b]],
      ["sorted", ->(_db, view) { view.each_key { |key| break key } }, "a"], # rubocop:disable Lint/UnreachableLoop -- Exercise early iterator exit.
      [nil, ->(_db, view) { view.dig("array", 1) }, 2],
      [nil, ->(_db, view) { view.to_ruby["array"] }, [1, 2, 3]],
      [nil, ->(_db, view) { view == view }, true], # rubocop:disable Lint/BinaryOperatorWithIdenticalOperands -- Test reflexive view comparison.
      [nil, ->(db, _view) { db.snapshot.revision.class }, XitDB::Revision],
      [nil, ->(db, _view) { db.history[0].revision.class }, XitDB::Revision],
      [nil, ->(db, _view) { db.history.size }, 1],
      [nil, ->(db, _view) { db.history.each { |snapshot| break snapshot.revision.class } }, XitDB::Revision] # rubocop:disable Lint/UnreachableLoop -- Exercise early iterator exit.
    ]
    operations.each_with_index do |(selector, operation, expected), index|
      database = open_database(path: File.join(@directory, "read-#{index}.xit"))
      database.transaction do |root|
        root["array"] = [1, 2, 3]
        root["linked"] = XitDB.linked_array
        root["linked"].push(1, 2, 3)
        root["set"] = Set["a"]
        root["sorted"] = XitDB.sorted_map
        root["sorted"].merge!({ "a" => 1, "b" => 2 })
      end
      view = database.snapshot
      view = view[selector] if selector
      entered = Queue.new
      release = Queue.new
      read = database.core.method(:read_at)
      reader_thread = nil
      blocked = false
      database.core.define_singleton_method(:read_at) do |*args, **kwargs|
        value = read.call(*args, **kwargs)
        if Thread.current == reader_thread && !blocked
          blocked = true
          entered << true
          release.pop
        end
        value
      end
      reader = in_thread do
        reader_thread = Thread.current
        operation.call(database, view)
      end
      Timeout.timeout(2) { entered.pop }
      closer = in_thread { database.close }
      Timeout.timeout(2) { Thread.pass until closer.status == "sleep" || !closer.alive? }
      waiting = closer.alive?
      release << true
      actual = join(reader)
      join(closer)

      assert waiting, "close did not wait for logical read #{index}"
      assert_equal expected, actual
    end
  end

  def test_fetch_defaults_and_iteration_callbacks_can_close_the_handle
    operations = [
      lambda { |db, root|
        root.fetch("missing") do
          db.close
          :closed
        end
      },
      lambda { |db, root|
        root["array"].fetch(9) do
          db.close
          :closed
        end
      },
      lambda { |db, root|
        root.each do # rubocop:disable Lint/UnreachableLoop -- Exercise close during early iterator exit.
          db.close
          break :closed
        end
      },
      lambda { |db, root|
        root["sorted"].from("a") do
          db.close
          break :closed
        end
      },
      lambda { |db, root|
        root["sorted"].page(offset: 0, limit: 1) do
          db.close
          break :closed
        end
      },
      lambda { |db, _root|
        db.history.each do # rubocop:disable Lint/UnreachableLoop -- Exercise close during early iterator exit.
          db.close
          break :closed
        end
      }
    ]
    operations.each_with_index do |operation, index|
      database = open_database(path: File.join(@directory, "callback-#{index}.xit"))
      root = database.transaction do |view|
        view["array"] = [1]
        view["sorted"] = XitDB.sorted_map
        view["sorted"]["a"] = 1
      end

      assert_equal :closed, operation.call(database, root)
      assert_predicate database, :closed?
    end
  end

  private

  def open_database(path: @path, **)
    database = XitDB.open(path, **)
    @handles << database
    database
  end

  def in_thread(&)
    thread = Thread.new(&)
    thread.report_on_exception = false
    @threads << thread
    thread
  end

  def join(thread)
    Timeout.timeout(5) { thread.value }
  end
end
