# frozen_string_literal: true

# Regression tests for the Steep coverage gate with real isolated sample projects.

require "test_helper"
require "bundler"
require "fileutils"
require "open3"
require "tmpdir"

# Checks the real Steep CLI and the repository's coverage gate in isolated projects.
# @api private
class TypeCoverageTest < Minitest::Test
  GATE = File.expand_path("../../script/check_type_coverage.rb", __dir__)

  # Checks plain rake checks checkout types without bundle exec.
  def test_plain_rake_checks_checkout_types_without_bundle_exec
    root = File.expand_path("../..", __dir__)
    environment = { "GEM_HOME" => Gem.dir, "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR) }
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e(environment, Gem.ruby, Gem.bin_path("rake", "rake"), "types", chdir: root)
    end

    assert_predicate status, :success?, output
    assert_includes output, "100% typed calls across"
  end

  # Creates an isolated Ruby project with signatures for coverage-gate tests.
  # @yieldparam directory [String] temporary project root
  def with_project
    Dir.mktmpdir("xitdb-type-coverage-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "lib/fixture"))
      FileUtils.mkdir_p(File.join(directory, "sig"))
      File.write(File.join(directory, "Steepfile"), "target :lib do\n  check 'lib'\n  signature 'sig'\nend\n")
      File.write(File.join(directory, "lib/fixture.rb"), <<~RUBY)
        class Fixture
          def call(value)
            value.to_s
          end
        end
      RUBY
      File.write(File.join(directory, "lib/fixture/value.rb"), "# frozen_string_literal: true\n")
      File.write(File.join(directory, "sig/fixture.rbs"), "class Fixture\n  def call: (String) -> String\nend\n")
      yield directory
    end
  end

  # Runs the type-coverage gate inside an isolated project.
  # @param directory [String] project root
  # @return [Array] combined output and process status
  def check(directory)
    Open3.capture2e(Gem.ruby, GATE, chdir: directory)
  end

  # Checks accepts fully typed files in nested directories.
  def test_accepts_fully_typed_files_in_nested_directories
    with_project do |directory|
      output, status = check(directory)

      assert_predicate status, :success?, output
      assert_includes output, "100% typed calls across 2 library files"
    end
  end

  # Checks rejects untyped calls.
  def test_rejects_untyped_calls
    with_project do |directory|
      File.write(File.join(directory, "sig/fixture.rbs"), "class Fixture\n  def call: (untyped) -> untyped\nend\n")
      output, status = check(directory)

      refute_predicate status, :success?, output
      assert_includes output, "Type coverage must be 100%"
    end
  end

  # Checks rejects omitted library files.
  def test_rejects_omitted_library_files
    with_project do |directory|
      File.write(File.join(directory, "Steepfile"), "target :lib do\n  check 'other'\n  signature 'sig'\nend\n")
      output, status = check(directory)

      refute_predicate status, :success?, output
      assert_includes output, "Steep must check every library file exactly once"
    end
  end
end
