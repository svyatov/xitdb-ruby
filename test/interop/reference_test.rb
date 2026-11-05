# frozen_string_literal: true

require "minitest/autorun"
require_relative "test_helper"

class ReferenceTest < Minitest::Test
  include ReferenceHelpers

  def test_reference_files_round_trip_all_core_kinds
    %w[go typescript java zig].each do |reference|
      with_reference(reference) do
        path = File.join(Interop::ROOT, "test/fixtures/interop", reference, "all-kinds.xit")
        assert File.file?(path), "missing independent #{reference} all-kinds fixture"
        assert_equal expected_values(reference), read_reference_fixture(reference, "all-kinds")
        assert_reference_reads_ruby_file(reference, "all-kinds")
        assert_reference_compacts_and_replicates_ruby_file(reference)
      end
    end
  end
end
