# frozen_string_literal: true

require "json"

# Pools every observation from an unchanged-source balanced confirmation.
module ConfirmationEvidence
  OPERATIONS = %w[insert read indexed update compact].freeze
  METRICS = %w[cpu_seconds seconds allocations].freeze
  SIZES = %w[initial_bytes update_bytes compacted_bytes].freeze
  CORRECTNESS = %w[insert read indexed update snapshot rollback compact].freeze
  POLICY = "All native observations pooled; other comparisons retain original balanced samples"

  def self.median(values)
    sorted = values.sort
    middle = sorted.size / 2
    (sorted[middle - 1] + sorted[middle]) / 2.0
  end

  def self.sample_metadata!(rows, confirmation)
    raise "confirmation sample coverage" unless rows.map { |row| row.fetch("sample") }.sort == (-2...12).to_a
    raise "confirmation warmup flags" unless rows.all? { |row| row.fetch("warmup") == row.fetch("sample").negative? }

    measured = rows.reject { |row| row.fetch("warmup") }.sort_by { |row| row.fetch("sample") }
    positions = measured.map { |row| row.fetch("position") }.tally
    raise "confirmation execution balance" if confirmation && positions != { 0 => 6, 1 => 6 }

    measured
  end

  def self.operation_values!(row)
    raise "confirmation operations" unless row.fetch("operations").keys.sort == OPERATIONS.sort

    row.fetch("operations").each_value do |values|
      valid = METRICS.all? { |metric| values.fetch(metric).finite? && values.fetch(metric) >= 0 }
      raise "confirmation metrics" unless valid
    end
    expected = row.fetch("store") == "file" ? CORRECTNESS + ["reopen"] : CORRECTNESS
    raise "confirmation correctness coverage" unless row.fetch("correctness") == expected
  end

  def self.measured!(rows, confirmation: false)
    measured = sample_metadata!(rows, confirmation)
    measured.each { |row| operation_values!(row) }
    measured
  end

  def self.source_match!(primary, confirmation)
    complete = primary["finished"] && confirmation["finished"] && primary.fetch("mode") == "production"
    raise "unfinished confirmation" unless complete

    worker = primary.fetch("harness").fetch("native_worker.rb")
    raise "confirmation worker mismatch" unless confirmation.fetch("worker_sha256") == worker

    variants = confirmation.fetch("results").map { |row| row.fetch("variant") }.uniq.sort
    raise "unexpected confirmation variant" unless variants == %w[compact o1]
  end

  def self.target_group!(failed, confirmation)
    keys = confirmation.fetch("results").map { |row| row.values_at("dataset", "count", "store") }.uniq
    raise "confirmation must identify exactly one group" unless keys.size == 1

    key = keys.first
    failed_groups = failed.fetch("failures").map { |row| row.values_at("dataset", "count", "store") }.uniq
    valid = failed.fetch("checks") == 444 && !failed.fetch("pass") && failed_groups.include?(key)
    raise "confirmation does not target a failed group" unless valid

    key
  end

  def self.distributions(rows)
    OPERATIONS.to_h do |operation|
      [operation, METRICS.to_h do |metric|
        values = rows.map { |row| row.fetch("operations").fetch(operation).fetch(metric) }
        [metric, { "median" => median(values), "min" => values.min, "max" => values.max }]
      end]
    end
  end

  def self.sizes!(group, rows)
    SIZES.each do |name|
      sizes = rows.map { |row| row.fetch(name) }.uniq
      raise "confirmation size mismatch" unless sizes == [group.fetch("sizes").fetch(name)]
    end
  end

  def self.pool_group!(primary, result, confirmation, key, variant)
    expected = primary.fetch("libraries").fetch(variant)
    raise "confirmation library mismatch" unless confirmation.fetch("libraries").fetch(variant) == expected

    original = primary.fetch("results").select do |row|
      row.values_at("dataset", "count", "store", "variant") == key + [variant]
    end
    fresh = confirmation.fetch("results").select { |row| row.fetch("variant") == variant }
    epochs = [measured!(original), measured!(fresh, confirmation: true)]
    pooled = epochs.flatten(1)
    group = result.fetch("groups").find do |row|
      row.values_at("dataset", "count", "store", "variant") == key + [variant]
    end
    raise "missing confirmation group" unless group

    sizes!(group, original + fresh)
    group["samples"] = 24
    group["epochs"] = { "matrix" => 12, "confirmation" => 12 }
    group["operations"] = distributions(pooled)
    [pooled, epochs]
  end

  def self.pair_metrics(paired)
    OPERATIONS.to_h do |operation|
      [operation, METRICS.to_h do |metric|
        ratios = paired.fetch("compact").zip(paired.fetch("o1")).flat_map do |left, right|
          left.zip(right).map do |candidate, control|
            observed = candidate.fetch("operations").fetch(operation).fetch(metric).to_f
            observed / control.fetch("operations").fetch(operation).fetch(metric)
          end
        end
        [metric, { "median_ratio" => median(ratios), "wins" => ratios.count { |ratio| ratio <= 1 }, "samples" => 24 }]
      end]
    end
  end

  def self.merge(primary, summary, failed, confirmation)
    source_match!(primary, confirmation)
    key = target_group!(failed, confirmation)
    result = JSON.parse(JSON.generate(summary))
    pooled = {}
    paired = {}
    %w[compact o1].each do |variant|
      pooled[variant], paired[variant] = pool_group!(primary, result, confirmation, key, variant)
    end
    inputs = pooled.values.flatten.map { |row| row.fetch("input_sha256") }.uniq
    raise "confirmation fixture mismatch" unless inputs.size == 1

    pair = result.fetch("pairs").find { |row| row.values_at("dataset", "count", "store", "control") == key + ["o1"] }
    raise "missing confirmation pair" unless pair

    pair["operations"] = pair_metrics(paired)
    result["confirmation"] = { "dataset" => key[0], "count" => key[1], "store" => key[2], "policy" => POLICY }
    result
  end
end

if $PROGRAM_NAME == __FILE__
  primary, summary, failed, confirmation, output = ARGV
  unless ARGV.size == 5 && !File.exist?(output)
    raise "primary run, summary, failed acceptance, confirmation, and new output required"
  end

  inputs = [primary, summary, failed, confirmation].map { |path| JSON.parse(File.read(path)) }
  File.write(output, JSON.pretty_generate(ConfirmationEvidence.merge(*inputs)))
  puts "Pooled all 24 native observations per variant for the confirmed group"
end
