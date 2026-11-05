# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

# Checks the real Steep CLI and the repository's coverage gate in isolated projects.
class TypeCoverageTest < Minitest::Test
  GATE = File.expand_path("../../script/check_type_coverage.rb", __dir__)

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

  def check(directory)
    Open3.capture2e(Gem.ruby, GATE, chdir: directory)
  end

  def test_accepts_fully_typed_files_in_nested_directories
    with_project do |directory|
      output, status = check(directory)
      assert status.success?, output
      assert_includes output, "100% typed calls across 2 library files"
    end
  end

  def test_rejects_untyped_calls
    with_project do |directory|
      File.write(File.join(directory, "sig/fixture.rbs"), "class Fixture\n  def call: (untyped) -> untyped\nend\n")
      output, status = check(directory)
      refute status.success?, output
      assert_includes output, "Type coverage must be 100%"
    end
  end

  def test_rejects_omitted_library_files
    with_project do |directory|
      File.write(File.join(directory, "Steepfile"), "target :lib do\n  check 'other'\n  signature 'sig'\nend\n")
      output, status = check(directory)
      refute status.success?, output
      assert_includes output, "Steep must check every library file exactly once"
    end
  end
end
