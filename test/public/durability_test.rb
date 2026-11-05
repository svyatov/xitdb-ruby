# frozen_string_literal: true

# Regression tests for durable publication, commit outcomes, and cooperating initializers.

require "test_helper"
require "support/fault_store"
require "tmpdir"
require "timeout"
require "xitdb/ruby"

# Covers durable publication, commit outcomes, and cooperating initializers.
# @api private
class PublicDurabilityTest < Minitest::Test
  # Creates a file-backed database behind FaultStore and commits the initial counter.
  def setup
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "database.xit")
    @real = XitDB::Core::FileStore.open(@path)
    @store = FaultStore.new(@real)
    core = XitDB::Core::Database.new(store: @store)
    @database = XitDB::Database.new(core: core, profile: XitDB::Profiles::Portable.new)
    @database.transaction { |root| root["counter"] = 0 }
  end

  # Disables fault hooks, closes the database, and removes its temporary directory.
  def teardown
    @store.fault = nil
    @store.release_fault = nil
    @database.close unless @database.closed?
    FileUtils.remove_entry(@directory)
  end

  # Checks that data sync failure is a known abort and allows a later write.
  def test_data_sync_failure_is_a_known_abort_and_allows_a_later_write
    fault = fail_sync(1)
    invocations = 0
    error = assert_raises(XitDB::CommitError) do
      @database.transaction do |root|
        invocations += 1
        root["counter"] = 1
      end
    end
    assert_equal :not_committed, error.outcome
    assert_same fault, error.cause
    assert_equal 1, invocations
    refute_predicate @database.core, :needs_reopen?
    assert_equal 0, @database.snapshot["counter"]
    assert_equal 1, @database.history.size
    assert_equal 2, @database.transaction { |root| root["counter"] = 2 }["counter"]
    assert_reopened_counter(2)
  end

  # Checks that header sync failure is unknown and never retries the callback.
  def test_header_sync_failure_is_unknown_and_never_retries_the_callback
    fault = fail_sync(2)
    invocations = 0
    error = assert_raises(XitDB::CommitError) do
      @database.transaction do |root|
        invocations += 1
        root["counter"] = 1
      end
    end
    assert_equal :unknown, error.outcome
    assert_same fault, error.cause
    assert_equal 1, invocations
    assert_predicate @database.core, :needs_reopen?
    assert_raises(XitDB::TransactionStateError) { @database.transaction { flunk "uncertain handle entered callback" } }
    # Visibility after failed fsync does not establish durability.
    assert_equal 1, @database.snapshot["counter"]
    @database.close

    assert_reopened_counter(1)
  end

  # Checks partial header publication is unknown and reopens at previous trailer.
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
    assert_predicate @database.core, :needs_reopen?
    @store.fault = nil
    @database.close
    reopened = XitDB.open(@path)

    assert_equal 0, reopened.snapshot["counter"]
    reopened.transaction { |root| root["counter"] = 2 }

    assert_equal reopened.core.committed_size, File.size(@path)
  ensure
    reopened&.close
  end

  # Checks that unlock failure after header sync is committed.
  def test_unlock_failure_after_header_sync_is_committed
    fault = IOError.new("unlock failed")
    @store.release_fault = -> { raise fault }
    invocations = 0
    error = assert_raises(XitDB::CommitError) do
      @database.transaction do |root|
        invocations += 1
        root["counter"] = 1
      end
    end
    assert_equal :committed, error.outcome
    assert_same fault, error.cause
    assert_equal 1, invocations
    assert_predicate @database.core, :needs_reopen?
    assert_raises(XitDB::TransactionStateError) { @database.transaction { flunk "failed handle entered callback" } }
    @store.release_fault = nil
    @database.close

    assert_reopened_counter(1)
  end

  # Checks callback error keeps identity and releases the writer.
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

  # Checks that process interruption after data sync keeps previous commit.
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

    assert_predicate status, :signaled?
    XitDB.open(@path) do |reopened|
      assert_equal 0, reopened.snapshot["counter"]
      assert_equal 1, reopened.history.size
      reopened.transaction { |root| root["counter"] = 2 }

      assert_equal 2, reopened.snapshot["counter"]
      assert_equal reopened.core.committed_size, File.size(@path)
    end
  ensure
    if pid
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
    [reader, writer].compact.each { |io| io.close unless io.closed? }
  end

  # Checks failed owned initialization and compaction release persistent write failures.
  def test_failed_owned_initialization_and_compaction_release_persistent_write_failures
    failure_cases = [[:open, 2], [:compact, 2], [:compact, 4]]
    [XitDB::Core::Database, XitDB, XitDB::Ruby].each do |api|
      failure_cases.each do |operation, failed_sync|
        path = File.join(@directory, "failed-#{api.name}-#{operation}-#{failed_sync}")
        failure = Errno::ENOSPC.new("persistent root write failure")
        captured = physical = source = before = nil
        original = XitDB::Core::FileStore.method(:open)
        XitDB::Core::FileStore.singleton_class.remove_method(:open)
        XitDB::Core::FileStore.define_singleton_method(:open) do |target, **options|
          original.call(target, **options).tap do |store|
            next unless target == path

            captured = store
            sync = store.method(:sync)
            calls = 0
            store.define_singleton_method(:sync) do
              calls += 1
              if calls == failed_sync
                file = store.instance_variable_get(:@file)
                write = file.method(:pwrite)
                partial = true
                file.define_singleton_method(:pwrite) do |bytes, offset|
                  if partial
                    partial = false
                    write.call(bytes.byteslice(0, 3), offset)
                  else
                    physical ||= File.binread(path)
                    raise failure
                  end
                end
              end
              sync.call
            end
          end
        end
        begin
          error = assert_raises(XitDB::CommitError) do
            if operation == :open
              api.open(path)
            else
              source = api.memory
              source.transaction do |root|
                api == XitDB::Core::Database ? root.replace(XitDB::Core::Slot.uint(1)) : root["value"] = 1
              end
              before = source.respond_to?(:snapshot) ? source.snapshot.to_ruby : source.root_cursor.slot
              source.compact(to: path)
            end
          end
          assert_equal :unknown, error.outcome
          assert_same failure, error.cause
          assert_predicate captured, :closed?, "unreturned store remains open: #{api} sync #{failed_sync}"
          assert_predicate captured.instance_variable_get(:@file), :closed?
          refute XitDB::Core::FileStore.const_get(:WRITERS).key?(captured.storage_identity)
          assert_equal physical, File.binread(path)
          if source
            assert_equal before,
                         source.respond_to?(:snapshot) ? source.snapshot.to_ruby : source.root_cursor.slot
          end
        ensure
          XitDB::Core::FileStore.singleton_class.remove_method(:open)
          XitDB::Core::FileStore.define_singleton_method(:open, original)
          captured&.close(discard: true)
          source&.close
          source = nil
        end
      end
    end
  end

  # Checks that new output names sync the directory after file data.
  def test_new_output_names_sync_the_directory_after_file_data
    durable_output_cases.each do |api, operation|
      path = File.join(@directory, "sync-#{api.name}-#{operation}")
      with_file_syncs do |events, files|
        output = create_output(api, operation, path)

        assert_equal %i[file directory], events.first(2), "#{api} #{operation}"
        assert_equal 1, events.count(:directory)
        assert(files.select { |_file, _, directory| directory }.all? { |file, _, _| file.closed? })
        output.close
      ensure
        output&.close
      end
      with_file_syncs do |events, _files|
        api.open(path) do |db|
          db.transaction { |root| api == XitDB::Core::Database ? root.replace(XitDB::Core::Slot.uint(2)) : root["value"] = 2 }

          assert_equal %i[file directory file], events
          events.clear
          db.transaction { |root| api == XitDB::Core::Database ? root.replace(XitDB::Core::Slot.uint(3)) : root["value"] = 3 }
        end

        assert_equal %i[file file], events
      end
    end
  end

  # Checks that directory sync failure preserves outcome and releases owned files.
  def test_directory_sync_failure_preserves_outcome_and_releases_owned_files
    empty_output_operations = %i[compact convert]
    durable_output_cases.each do |api, operation|
      path = File.join(@directory, "directory-failure-#{api.name}-#{operation}")
      failure = IOError.new("directory fsync failed")
      with_file_syncs(failure: failure) do |events, files|
        error = assert_raises(XitDB::CommitError) { create_output(api, operation, path) }
        assert_same failure, error.cause
        assert_equal(operation == :replica ? :unknown : :not_committed, error.outcome)
        assert_equal %i[file directory], events
        assert(files.all? { |file, _, _| file.closed? })
        files.reject { |_, _, directory| directory }.each do |_, identity, _|
          refute XitDB::Core::FileStore.const_get(:WRITERS).key?(identity)
        end
        assert_path_exists path
        assert_equal 0, File.size(path) if empty_output_operations.include?(operation)
      end
    end
  end

  # Checks cooperating thread initializer syncs name before creator resumes.
  def test_cooperating_thread_initializer_syncs_name_before_creator_resumes
    assert_cooperating_initializer(:thread)
  end

  # Checks cooperating process initializer syncs name before creator resumes.
  def test_cooperating_process_initializer_syncs_name_before_creator_resumes
    assert_cooperating_initializer(:process)
  end

  # Checks reopening valid uncertain output syncs name before committing.
  def test_reopening_valid_uncertain_output_syncs_name_before_committing
    path = File.join(@directory, "uncertain-replica")
    failure = IOError.new("directory fsync failed")
    with_file_syncs(failure: failure) do |events, files|
      error = assert_raises(XitDB::CommitError) { create_output(XitDB::Core::Database, :replica, path) }
      assert_equal :unknown, error.outcome
      assert_same failure, error.cause
      assert_equal %i[file directory], events
      assert(files.all? { |file, _, _| file.closed? })
    end
    uncertain = File.binread(path)
    with_file_syncs do |events, _files|
      XitDB::Core::Database.open(path, readonly: true) { |db| assert_equal 1, db.root_cursor.slot.value }
      assert_empty events
      assert_equal uncertain, File.binread(path)
      XitDB::Core::Database.open(path) do |db|
        assert_empty events
        assert_equal 1, db.root_cursor.slot.value
        db.transaction { |root| root.replace(XitDB::Core::Slot.uint(2)) }

        assert_equal %i[file directory file], events
        events.clear
        db.transaction { |root| root.replace(XitDB::Core::Slot.uint(3)) }

        assert_equal %i[file file], events
      end
    end
  end

  # Checks existing handle directory failure preserves previous commit.
  def test_existing_handle_directory_failure_preserves_previous_commit
    original = File.binread(@path)
    registrations = XitDB::Core::FileStore.const_get(:WRITERS).fetch(@real.storage_identity).last
    failure = IOError.new("existing directory fsync failed")
    with_file_syncs(failure: failure) do |events, files|
      XitDB.open(@path) do |db|
        calls = 0
        error = assert_raises(XitDB::CommitError) do
          db.transaction do |root|
            calls += 1
            root["counter"] = 1
          end
        end
        assert_equal :not_committed, error.outcome
        assert_same failure, error.cause
        assert_equal 1, calls
        assert_equal %i[file directory], events
        refute_predicate db.core, :needs_reopen?
        assert_equal 0, db.snapshot["counter"]
        assert_equal original, File.binread(@path)
      end
      assert(files.all? { |file, _, _| file.closed? })
      assert_equal registrations, XitDB::Core::FileStore.const_get(:WRITERS).fetch(@real.storage_identity).last
    end
  end

  private

  # Checks that a delayed initializer preserves another writer's committed root.
  # @param cooperation [Symbol] :thread or :process mode
  def assert_cooperating_initializer(cooperation)
    path = File.join(@directory, "cooperating-#{cooperation}")
    with_file_syncs do |events, _files|
      # Pause the creator at the same boundary as Database.open: store opened,
      # database construction and initialization lock not entered yet.
      created = XitDB::Core::FileStore.open(path)
      initialize_and_commit = lambda do
        XitDB::Core::Database.open(path) do |second|
          second.transaction { |root| root.replace(XitDB::Core::Slot.uint(7)) }
        end
        events.dup
      end
      observed = if cooperation == :thread
                   Thread.new(&initialize_and_commit).value
                 else
                   in_process(&initialize_and_commit)
                 end

      assert_equal %i[file directory file file file], observed, cooperation.to_s
      before = File.binread(path)
      creator = XitDB::Core::Database.new(store: created)

      assert_equal 7, creator.root_cursor.slot.value
      creator.close

      assert_equal before, File.binread(path)
      refute XitDB::Core::FileStore.const_get(:WRITERS).key?(created.storage_identity)
    ensure
      created&.close
    end
  end

  # Runs a block in a child process and returns its result through a pipe.
  # @yield executes the child operation
  # @return [Object] child result
  def in_process
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      begin
        Marshal.dump([:ok, yield], writer)
      rescue Exception => e # rubocop:disable Lint/RescueException -- Report Interrupt and fatal exceptions from the child process.
        Marshal.dump([:error, e.class.name, e.message], writer)
      ensure
        writer.close
      end
      exit! 0
    end
    writer.close
    result = Timeout.timeout(5) { Marshal.load(reader) } # rubocop:disable Security/MarshalLoad -- The private pipe contains only our forked child's result.
    _, status = Timeout.timeout(5) { Process.wait2(pid) }
    pid = nil

    assert_predicate status, :success?
    assert_equal :ok, result.first, result.inspect
    result.last
  ensure
    if pid
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
    [reader, writer].compact.each { |io| io.close unless io.closed? }
  end

  # Lists API and operation pairs that create durable output files.
  # @return [Array<Array>] API modules or classes paired with operation symbols
  def durable_output_cases
    [[XitDB::Core::Database, :open], [XitDB, :open], [XitDB::Ruby, :open],
     [XitDB::Core::Database, :compact], [XitDB, :compact], [XitDB::Ruby, :compact],
     [XitDB, :convert], [XitDB::Ruby, :convert], [XitDB::Core::Database, :replica]]
  end

  # Creates an output database through the selected API and operation.
  # @param api [Module] profile entry point or raw database class
  # @param operation [Symbol] :open, :compact, :convert, or :replica
  # @param path [String] destination path
  # @return [XitDB::Database, XitDB::Core::Database] open output
  def create_output(api, operation, path)
    return api.open(path) if operation == :open

    source = api.memory
    source.transaction do |root|
      api == XitDB::Core::Database ? root.replace(XitDB::Core::Slot.uint(1)) : root["value"] = 1
    end
    case operation
    when :compact then source.compact(to: path)
    when :convert then source.convert(to: path, profile: api == XitDB ? :portable : :ruby)
    when :replica
      store = source.instance_variable_get(:@store)
      bytes = store.read_at(0, store.length)
      api.copy_replica(to: path, source_io: StringIO.new(bytes), length: bytes.bytesize)
    end
  ensure
    source&.close
  end

  # Records file and directory fsync calls during an operation.
  # @param failure [Exception, nil] error raised during directory synchronization
  # @yieldparam events [Array<Symbol>] observed synchronization order
  # @yieldparam files [Array] opened files and identities
  def with_file_syncs(failure: nil)
    events = []
    files = []
    original = File.method(:open)
    File.define_singleton_method(:open) do |*args, **options, &block|
      file = original.call(*args, **options)
      stat = file.stat
      directory = stat.directory?
      files << [file, [Process.pid, stat.dev, stat.ino], directory]
      sync = file.method(:fsync)
      file.define_singleton_method(:fsync) do
        events << (directory ? :directory : :file)
        raise failure if directory && failure

        sync.call
      end
      if block
        begin
          block.call(file)
        ensure
          file.close
        end
      else
        file
      end
    end
    yield events, files
  ensure
    File.singleton_class.remove_method(:open)
  end

  # Makes the selected fsync call fail on the underlying database file.
  # @param number [Integer] one-based call number to fail
  # @return [IOError] injected exception
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

  # Reopens the file to check the counter after a publication outcome.
  # @param expected [Integer] expected committed counter
  def assert_reopened_counter(expected)
    XitDB.open(@path) { |reopened| assert_equal expected, reopened.snapshot["counter"] }
  end
end
