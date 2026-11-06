# frozen_string_literal: true

# Regression tests for large-data operations under a hard memory budget and benchmark reports.

require "test_helper"
require "json"
require "open3"
require "tmpdir"
require_relative "workload"

# Covers large-data operations under a hard memory budget and benchmark reports.
# @api private
class MemoryStressTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # Checks fixture uses profile specific sorted keys.
  def test_fixture_uses_profile_specific_sorted_keys
    %w[portable ruby].each do |profile|
      database = BoundedWorkload.open_database(profile)
      begin
        digest = BoundedWorkload.fixture(database, bytes: 3, rows: 3)

        assert_equal 2, database.history.size
        assert_equal 1, database.snapshot["rows"]["row-00000001"]
        assert_equal "012", database.snapshot.open_bytes("blob", &:read)
        assert_equal Digest::SHA256.hexdigest("012"), digest
      ensure
        database.close
      end
    end
  end

  # Checks converted string verification reads both profiles incrementally.
  def test_converted_string_verification_reads_both_profiles_incrementally
    Dir.mktmpdir("xitdb-byte-check-") do |directory|
      %w[portable ruby].each do |profile|
        source = BoundedWorkload.open_database(profile)
        target = nil
        begin
          source.transaction { |root| root.write_bytes("blob") { |writer| writer.write("abc") } }
          target = source.convert(to: File.join(directory, profile), profile: profile == "ruby" ? :portable : :ruby)
          BoundedWorkload.bound_reads(target)
          digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

          assert_nil BoundedWorkload.check_stream!(target, 3, digest, converted: true)
          assert_raises(RuntimeError) { BoundedWorkload.check_stream!(target, 4, "invalid", converted: true) }
        ensure
          target&.close
          source.close
        end
      end
    end
  end

  # Checks lookup, pagination, conversion, and compaction when the dataset exceeds the container memory limit.
  def test_lookup_pagination_conversion_and_compaction_below_dataset_size
    output = if ENV["XITDB_STRESS_REPORT"]
               File.read(ENV.fetch("XITDB_STRESS_REPORT"))
             else
               stdout, error, status = Open3.capture3(
                 "ruby", "script/stress.rb", "--limit-mib", "256", "--data-mib", "768", chdir: ROOT
               )

               assert_predicate status, :success?, error
               stdout
             end
    FileUtils.mkdir_p(File.join(ROOT, "pkg"))
    File.write(File.join(ROOT, "pkg/stress.json"), output)
    report = JSON.parse(output)

    assert_equal "cgroup_v2", report.fetch("hard_limit_mechanism")
    assert_equal 268_435_456, report.fetch("memory_limit_bytes")
    assert_equal 0, report.fetch("swap_limit_bytes")
    high = report.fetch("memory_high_bytes")
    assert_equal 201_326_592, high unless high == "max"

    assert_equal(%w[portable ruby], report.fetch("profiles").map { |entry| entry.fetch("profile") })
    report.fetch("profiles").each do |entry|
      assert_operator entry.fetch("dataset_bytes"), :>, report.fetch("memory_limit_bytes")
      assert_equal 805_306_368, entry.fetch("payload_bytes")
      assert_equal %w[lookup pagination stream conversion compaction], entry.fetch("completed")
      assert_operator entry.fetch("offset_cache_peak_entries"), :<=, 16_384
      assert_operator entry.fetch("offset_cache_peak_entries"), :>, 0
      assert_equal 2, entry.fetch("conversion_history_count")
      assert_equal 1, entry.fetch("compaction_history_count")
    end
    assert_operator report.fetch("memory_peak_bytes"), :<=, report.fetch("memory_limit_bytes")
    assert_equal 0, report.fetch("memory_events").fetch("oom")
    assert_equal 0, report.fetch("memory_events").fetch("oom_kill")
  end

  # Checks benchmark records measured samples and bounded history diagnostic.
  def test_benchmark_records_measured_samples_and_bounded_history_diagnostic
    Dir.mktmpdir("xitdb-benchmark-test-") do |directory|
      path = File.join(directory, "benchmark.json")
      _output, error, status = Open3.capture3("ruby", "script/benchmark.rb", "--output", path, chdir: ROOT)

      assert_predicate status, :success?, error
      report = JSON.parse(File.read(path))

      assert_match(/ruby/, report.fetch("ruby_description"))
      assert_equal "unavailable", report.fetch("os_cache_control")
      assert_equal 8, report.fetch("workloads").size
      report.fetch("workloads").each do |entry|
        assert_includes %w[file memory], entry.fetch("storage")
        assert_includes %w[first_handle warm_handle fresh_handle], entry.fetch("handle_state")
        assert_operator entry.fetch("dataset_bytes"), :>, 0
        assert_equal %w[lookup pagination stream conversion compaction], entry.fetch("operations").keys
        entry.fetch("operations").each_value do |measurement|
          assert_equal 3, measurement.fetch("elapsed_seconds").size
          assert_equal 3, measurement.fetch("allocated_objects").size
          assert_operator measurement.fetch("median_seconds"), :>=, 0
        end
      end

      assert_equal 4, report.fetch("shared_histories").size
      report.fetch("shared_histories").each do |entry|
        assert_includes %w[completed timeout], entry.fetch("status")
        assert_operator entry.fetch("fixture_seconds"), :>=, 0
        assert_operator entry.fetch("conversion_seconds"), :>=, 0
        assert_equal 25, entry.fetch("history_length")
        assert_equal 0, entry.fetch("destination_bytes") if entry.fetch("status") == "timeout"
      end
    end
  end
end
