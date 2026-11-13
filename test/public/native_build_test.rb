# frozen_string_literal: true

require_relative "../test_helper"
require "bundler"
require "open3"
require "rbconfig"
require "tmpdir"

# Checks the standalone Ruby runtime used before the Linux memory measurement.
class NativeBuildTest < Minitest::Test
  def test_stress_runtime_builds_without_development_gems_or_checkout_load_paths
    root = File.expand_path("../..", __dir__)
    Dir.mktmpdir("xitdb-native-build-") do |directory|
      runtime = File.join(directory, "runtime")
      output, status = Bundler.with_unbundled_env do
        Open3.capture2e(RbConfig.ruby, File.join(root, "script/stress_build.rb"), runtime)
      end

      assert_predicate status, :success?, output
      script = 'require_relative "test/stress/workload"; puts XitDB::Ruby::PageCodec.decode_page("XP01\\x01\\x00")'
      output, status = Bundler.with_unbundled_env do
        Open3.capture2e(RbConfig.ruby, "-e", script, chdir: runtime)
      end

      assert_predicate status, :success?, output
      assert_equal "{}\n", output
      refute_path_exists File.join(runtime, "Gemfile")
      assert File.file?(File.join(runtime, "lib/xitdb/ruby/page_codec.rb"))
      assert_empty Dir[File.join(runtime, "**/*.{c,so,bundle,dll}")]
      _output, status = Bundler.with_unbundled_env do
        Open3.capture2e(RbConfig.ruby, File.join(root, "script/stress_build.rb"), runtime)
      end

      refute_predicate status, :success?
    end
  end
end
