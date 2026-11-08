# frozen_string_literal: true

# Builds large fixtures and measures database operations inside a Docker memory limit.
# The command-line entry point runs inside the container.

require "json"
require "digest"
require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"
require "timeout"
require_relative "../../lib/xitdb/ruby"

# Provides bounded fixtures, measured operations, and isolated workload execution.
# @api private
module BoundedWorkload
  MIB = 1024 * 1024
  CHUNK = ("0123456789abcdef" * 4096).b.freeze

  # Retain one integer, never the maps or their entries.
  # @api private
  module OffsetPeak
    class << self
      attr_accessor :entries
    end
    self.entries = 0

    # Records the peak offset-cache entry count before closing the map.
    # @return [Object] result from the wrapped close
    def close
      OffsetPeak.entries = [OffsetPeak.entries, peak_cache_size].max
      super
    end
  end
  XitDB::Core::OffsetMap.prepend(OffsetPeak)

  # Runs a workload in a read-only Docker container with a hard memory limit.
  # @param mode [String] stress or benchmark
  # @param limit_mib [Integer] memory limit in MiB, at least 64
  # @param data_mib [Integer, nil] stress payload size in MiB
  # @return [Hash] workload and host disk-space report
  def self.isolate(mode, limit_mib:, data_mib: nil)
    raise ArgumentError, "memory limit must be at least 64 MiB" if limit_mib < 64
    raise ArgumentError, "data size must be positive" if data_mib && data_mib <= 0

    Dir.mktmpdir("xitdb-#{mode}-") do |directory|
      output, status = Open3.capture2("df", "-Pk", directory)
      raise "disk-space check failed" unless status.success?

      available = Integer(output.lines.last.split.fetch(3)) * 1024
      required = ((data_mib || 1) * MIB * 4) + (64 * MIB)
      raise "need #{required} free bytes, found #{available}" if available < required

      name = "xitdb-#{SecureRandom.hex(8)}"
      driver, status = Open3.capture2("docker", "info", "--format", "{{.CgroupDriver}}")
      raise "Docker cgroup-driver check failed" unless status.success?

      high = driver.strip == "systemd" ? (limit_mib * MIB * 3 / 4).to_s : "max"
      reclaim = high == "max" ? [] : ["--annotation", "org.systemd.property.MemoryHigh=uint64 #{high}"]
      build_runtime(directory)
      work = File.join(directory, "work")
      FileUtils.mkdir_p(work)
      command = ["docker", "run", "--pull=never", "--network=none", "--rm", "--name", name,
                 *reclaim,
                 "--memory", "#{limit_mib}m", "--memory-swap", "#{limit_mib}m", "--read-only",
                 "--mount", "type=bind,src=#{directory}/runtime,dst=/repo,readonly",
                 "--mount", "type=bind,src=#{work},dst=/work", "--workdir", "/repo",
                 "--env", "TMPDIR=/work", "--env", "XITDB_MEMORY_HIGH=#{high}",
                 "ruby:4.0.9", "ruby", "test/stress/workload.rb",
                 mode, "/work", (limit_mib * MIB).to_s, (data_mib || 1).to_s]
      begin
        stdout, stderr, result = Open3.capture3(*command)
        raise "isolated workload failed (#{result.exitstatus}): #{stderr}\n#{stdout}" unless result.success?

        report = JSON.parse(stdout)
        report["host_available_bytes_before"] = available
        report
      ensure
        system("docker", "rm", "--force", name, out: File::NULL, err: File::NULL) unless result&.success?
      end
    end
  end

  # Compiles for the container's Ruby before measuring the workload cgroup.
  def self.build_runtime(directory)
    command = ["docker", "run", "--pull=never", "--network=none", "--rm", "--read-only",
               "--user", "#{Process.uid}:#{Process.gid}",
               "--mount", "type=bind,src=#{File.expand_path("../..", __dir__)},dst=/repo,readonly",
               "--mount", "type=bind,src=#{directory},dst=/work", "--workdir", "/work",
               "--env", "TMPDIR=/work", "ruby:4.0.9", "ruby", "/repo/script/stress_build.rb", "/work/runtime"]
    output, status = Open3.capture2e(*command)
    raise "isolated native codec build failed (#{status.exitstatus}): #{output}" unless status.success?
  end

  # Verifies Linux cgroup memory and swap limits before fixture allocation.
  # @param limit [Integer] requested hard limit in bytes
  # @return [Hash] verified limits and runtime details
  def self.hard_budget(limit)
    raise "isolated Linux is required" unless RUBY_PLATFORM.include?("linux")

    maximum = Integer(File.read("/sys/fs/cgroup/memory.max"))
    swap = Integer(File.read("/sys/fs/cgroup/memory.swap.max"))
    high = File.read("/sys/fs/cgroup/memory.high").strip
    raise "Linux hard memory budget does not match request" unless maximum == limit && swap.zero?
    raise "Linux reclaim threshold does not match request" unless high == ENV.fetch("XITDB_MEMORY_HIGH", "max")

    { "hard_limit_mechanism" => "cgroup_v2", "memory_limit_bytes" => maximum, "swap_limit_bytes" => swap,
      "memory_high_bytes" => high == "max" ? high : Integer(high),
      "ruby_description" => RUBY_DESCRIPTION, "platform" => RUBY_PLATFORM }
  end

  # Measures elapsed time and Ruby allocations around an operation.
  # @yield performs the measured operation
  # @return [Array] result, elapsed seconds, and allocated object count
  def self.measure
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = yield
    [value, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, GC.stat(:total_allocated_objects) - allocated]
  end

  # Writes Linux cgroup and garbage collector statistics to standard error.
  # @param phase [String] operation label
  # @return [nil]
  def self.trace(phase)
    return unless RUBY_PLATFORM.include?("linux")

    stats = File.read("/sys/fs/cgroup/memory.stat").lines.to_h(&:split)
    warn JSON.generate(phase: phase, memory_bytes: File.read("/sys/fs/cgroup/memory.current").to_i,
                       memory: stats.slice("anon", "file", "file_dirty", "file_writeback"),
                       gc: GC.stat.slice(:heap_live_slots, :heap_allocated_pages, :malloc_increase_bytes))
  end

  # Opens a file-backed or memory database with the selected value profile.
  # @param profile [String] ruby for Ruby values, otherwise portable
  # @param path [String, nil] path, or nil for memory storage
  # @return [XitDB::Database] open database
  def self.open_database(profile, path = nil)
    implementation = profile == "ruby" ? XitDB::Ruby : XitDB
    path ? implementation.open(path) : implementation.memory
  end

  # Builds a fixed-width key whose byte order matches its numeric index.
  # @param index [Integer] row index
  # @return [String] ordered row key
  def self.key(index)
    format("row-%08d", index)
  end

  # Writes indexed rows, a streamed blob, and two revisions for verification.
  # @param database [XitDB::Database] empty fixture database
  # @param bytes [Integer] blob size
  # @param rows [Integer] indexed row count
  # @return [String] blob SHA-256 hexadecimal digest
  def self.fixture(database, bytes:, rows:)
    digest = Digest::SHA256.new
    database.transaction do |root|
      root["rows"] = database.profile.is_a?(XitDB::Profiles::Ruby) ? XitDB.sorted_map(key: :string) : XitDB.sorted_map
      rows.times { |index| root["rows"][key(index)] = index }
      root.write_bytes("blob") do |writer|
        remaining = bytes
        while remaining.positive?
          chunk = remaining >= CHUNK.bytesize ? CHUNK : CHUNK.byteslice(0, remaining)
          writer.write(chunk)
          digest.update(chunk)
          remaining -= chunk.bytesize
        end
      end
      root["revision"] = 0
    end
    database.transaction { |root| root["revision"] = 1 }
    digest.hexdigest
  end

  # Rejects source reads above 64 KiB to expose unbounded payload reads.
  # @param database [XitDB::Database] handle to instrument
  def self.bound_reads(database)
    database.core.define_singleton_method(:read_at) do |offset, length, **options|
      raise "source read exceeds 64 KiB: #{length}" if length > 65_536

      super(offset, length, **options)
    end
  end

  # Checks first, middle, and last row lookups plus an absent key.
  # @param database [XitDB::Database] fixture database
  # @param rows [Integer] expected row count
  def self.check_index!(database, rows)
    index = database.snapshot["rows"]
    [0, rows / 2, rows - 1].each do |position|
      raise "lookup mismatch" unless index[key(position)] == position
    end
    raise "absent key found" unless index["absent"].nil?
  end

  # Checks all rows through pages of 37 entries without losing rank or progress.
  # @param database [XitDB::Database] fixture database
  # @param rows [Integer] expected row count
  def self.check_pages!(database, rows)
    index = database.snapshot["rows"]
    position = 0
    while position < rows
      count = 0
      index.page(offset: position, limit: 37) do |stored_key, value|
        raise "pagination mismatch" unless stored_key == key(position + count) && value == position + count

        count += 1
      end
      raise "pagination made no progress" unless count == [37, rows - position].min

      position += count
    end
  end

  # Checks blob length and digest with reads of at most 64 KiB.
  # @param database [XitDB::Database] fixture or converted database
  # @param bytes [Integer] expected blob size
  # @param digest [String] expected SHA-256 digest
  # @param converted [Boolean] whether to use the conversion byte interface
  def self.check_stream!(database, bytes, digest, converted: false)
    actual = Digest::SHA256.new
    count = 0
    if converted
      snapshot = database.snapshot
      source, = database.profile.conversion_bytes(snapshot.adapter.lookup("blob"), context: snapshot.context)
      raise "converted byte size mismatch" unless source.size == bytes

      while count < source.size
        chunk = source.read(count, [65_536, source.size - count].min)
        actual.update(chunk)
        count += chunk.bytesize
      end
    else
      database.snapshot.open_bytes("blob") do |reader|
        raise "stream size mismatch" unless reader.size == bytes

        while (chunk = reader.read(65_536))
          actual.update(chunk)
          count += chunk.bytesize
        end
      end
    end
    raise "stream contents mismatch" unless count == bytes && actual.hexdigest == digest
  end

  # Measures lookup, pagination, streaming, conversion, and compaction, then verifies results.
  # @param database [XitDB::Database] source fixture
  # @param profile [String] source profile
  # @param bytes [Integer] expected blob size
  # @param rows [Integer] expected row count
  # @param digest [String] expected blob digest
  # @param directory [String] scratch directory
  # @return [Hash] timings, allocations, and output details
  def self.operations(database, profile:, bytes:, rows:, digest:, directory:)
    measurements = {}
    %w[lookup pagination stream].each do |operation|
      trace("#{profile}:#{operation}")
      _, elapsed, allocated = measure do
        case operation
        when "lookup" then check_index!(database, rows)
        when "pagination" then check_pages!(database, rows)
        when "stream" then check_stream!(database, bytes, digest)
        end
      end
      measurements[operation] = { "seconds" => elapsed, "allocations" => allocated }
    end
    %w[conversion compaction].each do |operation|
      trace("#{profile}:#{operation}")
      path = File.join(directory, "#{operation}.xit")
      target = nil
      begin
        target, elapsed, allocated = measure do
          if operation == "conversion"
            database.convert(to: path,
                             profile: profile == "ruby" ? :portable : :ruby)
          else
            database.compact(to: path)
          end
        end
        expected_history = operation == "conversion" ? 2 : 1
        _, verification, = measure do
          bound_reads(target)
          raise "history count mismatch" unless target.history.size == expected_history
          raise "latest revision mismatch" unless target.snapshot["revision"] == 1
          raise "first revision mismatch" if operation == "conversion" && target.history[0]["revision"] != 0

          check_index!(target, rows)
          check_pages!(target, rows)
          check_stream!(target, bytes, digest, converted: operation == "conversion")
        end
        measurements[operation] = { "seconds" => elapsed, "allocations" => allocated,
                                    "verification_seconds" => verification, "destination_bytes" => File.size(path),
                                    "history_count" => target.history.size }
      ensure
        target&.close
        FileUtils.rm_f(path)
      end
    end
    measurements
  end

  # Runs the large-data fixture and measured operations for both profiles.
  # @param directory [String] scratch directory
  # @param bytes [Integer] blob size
  # @return [Array<Hash>] portable and Ruby reports
  def self.stress(directory, bytes)
    %w[portable ruby].map do |profile|
      path = File.join(directory, "source.xit")
      database = open_database(profile, path)
      begin
        trace("#{profile}:fixture")
        digest, creation, allocations = measure { fixture(database, bytes: bytes, rows: 8192) }
        size = File.size(path)
        raise "physical dataset is smaller than payload" if size < bytes

        bound_reads(database)
        OffsetPeak.entries = 0
        measured = operations(database, profile: profile, bytes: bytes, rows: 8192, digest: digest,
                                        directory: directory)
        { "profile" => profile, "dataset_bytes" => size, "payload_bytes" => bytes, "rows" => 8192,
          "fixture_seconds" => creation, "fixture_allocated_objects" => allocations, "operations" => measured,
          "completed" => measured.keys, "offset_cache_peak_entries" => OffsetPeak.entries,
          "conversion_history_count" => measured.fetch("conversion").fetch("history_count"),
          "compaction_history_count" => measured.fetch("compaction").fetch("history_count") }
      ensure
        database.close
        FileUtils.rm_f(path)
      end
    end
  end

  # Collects three samples for each profile, storage kind, and handle state.
  # @param directory [String] scratch directory
  # @return [Array<Hash>] sample timings, allocations, and statistics
  def self.benchmarks(directory)
    workloads = []
    storage_kinds = %w[file memory]
    %w[portable ruby].each do |profile|
      storage_kinds.each do |storage|
        states = storage == "file" ? %w[fresh_handle warm_handle] : %w[first_handle warm_handle]
        states.each do |state|
          entry = { "profile" => profile, "storage" => storage, "handle_state" => state,
                    "payload_bytes" => MIB, "rows" => 256, "history_length" => 2, "operations" => {} }
          database = nil
          digest = nil
          path = storage == "file" ? File.join(directory, "source.xit") : nil
          begin
            3.times do
              if database.nil?
                database = open_database(profile, path)
                digest, creation, = measure { fixture(database, bytes: MIB, rows: 256) }
                entry["fixture_seconds"] ||= []
                entry["fixture_seconds"] << creation
                entry["dataset_bytes"] = path ? File.size(path) : database.core.root_cursor.bound
                bound_reads(database)
                if state == "warm_handle"
                  operations(database, profile: profile, bytes: MIB, rows: 256, digest: digest,
                                       directory: directory)
                end
              end
              if state == "fresh_handle"
                database.close
                database = open_database(profile, path)
                bound_reads(database)
              end
              measured = operations(database, profile: profile, bytes: MIB, rows: 256, digest: digest,
                                              directory: directory)
              measured.each do |name, sample|
                aggregate = entry["operations"][name] ||= { "elapsed_seconds" => [], "allocated_objects" => [] }
                aggregate["elapsed_seconds"] << sample.fetch("seconds")
                aggregate["allocated_objects"] << sample.fetch("allocations")
                aggregate["destination_bytes"] = sample["destination_bytes"] if sample.key?("destination_bytes")
                if sample.key?("verification_seconds")
                  (aggregate["verification_seconds"] ||= []) << sample["verification_seconds"]
                end
              end
              if state == "first_handle"
                database.close
                database = nil
              end
            end
            entry["operations"].each_value do |sample|
              sorted = sample.fetch("elapsed_seconds").sort
              sample.merge!("minimum_seconds" => sorted.first, "median_seconds" => sorted[1],
                            "maximum_seconds" => sorted.last)
            end
            workloads << entry
          ensure
            database&.close
            File.unlink(path) if path && File.exist?(path)
          end
        end
      end
    end
    workloads
  end

  # Measures conversion of 25 revisions sharing arrays, with optional deep nesting.
  # @param directory [String] scratch directory
  # @return [Array<Hash>] reports including timeout and verification results
  def self.shared_histories(directory)
    depths = [0, 600]
    %w[portable ruby].flat_map do |profile|
      depths.map do |depth|
        source_path = File.join(directory, "shared.xit")
        destination = File.join(directory, "shared-copy.xit")
        database = open_database(profile, source_path)
        target = nil
        begin
          _, creation, = measure do
            nested = "leaf"
            depth.times { nested = [nested] }
            database.transaction do |root|
              root["deep"] = nested if depth.positive?
              root["shared"] = Array.new(depth.zero? ? 128 : 64) { |index| index }
              root["revision"] = 0
            end
            24.times { |index| database.transaction { |root| root["revision"] = index + 1 } }
          end
          entry = { "profile" => profile, "depth" => depth, "history_length" => 25,
                    "shared_array_length" => depth.zero? ? 128 : 64, "fixture_seconds" => creation,
                    "source_bytes" => File.size(source_path), "timeout_seconds" => 10 }
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            target, elapsed, allocated = measure do
              Timeout.timeout(10) { database.convert(to: destination, profile: profile == "ruby" ? :portable : :ruby) }
            end
            entry.merge!("status" => "completed", "conversion_seconds" => elapsed, "allocated_objects" => allocated)
            _, verification, = measure do
              raise "shared history mismatch" unless target.history.size == 25 && target.snapshot["revision"] == 24

              target.history.each do |snapshot|
                raise "shared array mismatch" unless snapshot["shared"][-1] == (depth.zero? ? 127 : 63)

                next unless depth.positive?

                value = snapshot["deep"]
                depth.times { value = value[0] }
                raise "deep leaf mismatch" unless value == "leaf"
              end
            end
            entry["verification_seconds"] = verification
          rescue Timeout::Error
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            entry.merge!("status" => "timeout", "conversion_seconds" => elapsed,
                         "verification_seconds" => nil)
          end
          entry["destination_bytes"] = File.size(destination)
          entry["output_to_source_ratio"] = entry["destination_bytes"].fdiv(entry["source_bytes"])
          entry
        ensure
          target&.close
          database.close
          [source_path, destination].each { |path| FileUtils.rm_f(path) }
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  mode, directory, limit, data_mib = ARGV
  report = BoundedWorkload.hard_budget(Integer(limit))
  case mode
  when "native-string", "native-rows"
    require_relative "native_workload"
    report["native"] = NativeWorkload.run(mode.delete_prefix("native-"), directory)
  when "stress" then report["profiles"] = BoundedWorkload.stress(directory, Integer(data_mib) * BoundedWorkload::MIB)
  when "benchmark"
    report["os_cache_control"] = "unavailable"
    report["workloads"] = BoundedWorkload.benchmarks(directory)
    report["shared_histories"] = BoundedWorkload.shared_histories(directory)
  else raise ArgumentError, "unknown workload: #{mode}"
  end
  report["memory_peak_bytes"] = Integer(File.read("/sys/fs/cgroup/memory.peak"))
  report["memory_events"] = File.read("/sys/fs/cgroup/memory.events").lines.to_h do |line|
    name, value = line.split
    [name, Integer(value)]
  end
  puts JSON.generate(report)
end
