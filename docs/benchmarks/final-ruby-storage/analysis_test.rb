# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "zlib"
require_relative "merge_confirmation"

# Exercises confirmation invariants using only the adjacent archived inputs.
class ConfirmationEvidenceTest < Minitest::Test
  def setup
    names = %w[production-run production-primary-summary production-primary-acceptance production-confirmation-run]
    @primary, @summary, @failed, @confirmation = names.map do |name|
      JSON.parse(Zlib::GzipReader.open(File.join(__dir__, "#{name}.json.gz"), &:read))
    end
  end

  def merge
    ConfirmationEvidence.merge(@primary, @summary, @failed, @confirmation)
  end

  def test_all_original_observations_are_retained
    original = @primary.fetch("results").find do |row|
      row.values_at("variant", "dataset", "count", "store", "sample") == ["compact", "application", 1000, "memory", 0]
    end
    original["operations"]["insert"]["cpu_seconds"] = 1000.0
    result = merge
    group = result.fetch("groups").find do |row|
      row.values_at("variant", "dataset", "count", "store") == ["compact", "application", 1000, "memory"]
    end

    assert_equal 24, group.fetch("samples")
    assert_in_delta(1000.0, group.fetch("operations").fetch("insert").fetch("cpu_seconds").fetch("max"))
    assert_equal 96, result.fetch("groups").size
  end

  def test_changed_implementation_cannot_be_pooled
    @confirmation["libraries"]["compact"]["lib/xitdb/ruby.rb"] = "changed"

    assert_match(/library mismatch/, assert_raises(RuntimeError) { merge }.message)
  end

  def test_missing_sample_cannot_be_pooled
    @confirmation["results"].reject! { |row| row["variant"] == "compact" && row.fetch("sample").zero? }

    assert_match(/sample coverage/, assert_raises(RuntimeError) { merge }.message)
  end

  def test_negative_measurements_are_rejected
    @confirmation["results"].find { |row| !row["warmup"] }["operations"]["insert"]["cpu_seconds"] = -1.0

    assert_match(/confirmation metrics/, assert_raises(RuntimeError) { merge }.message)
  end

  def test_confirmation_cannot_replace_a_passing_group
    @failed["pass"] = true

    assert_match(/does not target a failed group/, assert_raises(RuntimeError) { merge }.message)
  end
end
