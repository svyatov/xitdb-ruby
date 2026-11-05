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

  source_states = %w[missing empty]
  %w[read compact replicate].each do |operation|
    source_states.each do |state|
      define_method("test_typescript_#{operation}_rejects_#{state}_source_unchanged") do
        with_reference("typescript") do
          path = File.join(@directory, "source.xit")
          File.binwrite(path, "") if state == "empty"
          output, error, status = typescript_request(operation, path)

          assert_equal state == "empty", File.exist?(path), error
          assert_equal "", File.binread(path) if state == "empty"

          assert_empty Dir.glob("#{path}.*"), error
          refute_predicate status, :success?, "#{operation} accepted #{state} source: #{output}"
          assert_empty output
        end
      end
    end
  end

  def test_typescript_invalid_operation_does_not_create_source
    with_reference("typescript") do
      path = File.join(@directory, "source.xit")
      output, error, status = typescript_request("destroy", path)

      refute_path_exists path
      assert_empty Dir.glob("#{path}.*")
      refute_predicate status, :success?
      assert_empty output
      assert_match(/unsupported operation/, error)
    end
  end

  def test_typescript_source_operations_accept_readonly_file
    with_reference("typescript") do
      path = File.join(@directory, "source.xit")
      Interop.write_tree(path)
      original = File.binread(path)
      File.chmod(0o444, path)

      assert_equal Interop.expected_tree(linked_hole: true), @invoke.call("read", "all-kinds", path).fetch("tree")
      Interop.check_maintenance(@invoke, path, Interop.expected_tree(linked_hole: true))

      assert_equal original, File.binread(path)
      assert_equal 0o444, File.stat(path).mode & 0o777
    end
  end

  private

  def typescript_request(operation, path)
    source = ENV.fetch("XITDB_TYPESCRIPT_REFERENCE", "/private/tmp/xitdb-reference-typescript")
    request = { operation: operation, case: "all-kinds", path: path, hash: Interop::MANIFEST.fetch("hash") }
    Open3.capture3({ "MISE_CACHE_DIR" => "/private/tmp/xitdb-mise-cache", "XITDB_REFERENCE" => source },
                   "bun", File.join(Interop::ROOT, "test/interop/typescript/main.ts"),
                   stdin_data: JSON.generate(request))
  end
end
