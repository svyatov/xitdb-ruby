# frozen_string_literal: true

# Regression tests for installed gem files, runtime dependencies, and packaged examples.

require_relative "../test_helper"
require_relative "../support/package_helpers"

# Covers installed gem files, runtime dependencies, and packaged examples.
# @api private
class PackageTest < Minitest::Test
  include PackageHelpers

  # Checks that built gem loads both profiles in a clean bundle.
  def test_built_gem_loads_both_profiles_in_a_clean_bundle
    with_built_package do |spec|
      assert_equal "Ada", packaged_example("portable").fetch("name")
      assert_same true, packaged_example("ruby").fetch("enabled")
      assert_equal %w[Ada Grace], packaged_example("indexed_users").fetch("names")
      %w[README.md CHANGELOG.md LICENSE docs/core.md docs/portable.md docs/ruby.md
         docs/ruby-profile-v1.md docs/ruby-profile-v2.md sig/base.rbs sig/core.rbs sig/native.rbs sig/public.rbs
         sig/ruby.rbs sig/manifest.yaml].each do |path|
        assert_includes spec.files, path
      end
      assert_equal ["ext/xitdb/page_codec/extconf.rb"], spec.extensions
      assert_includes spec.files, "ext/xitdb/page_codec/page_codec.c"
      assert_equal %w[bigdecimal date], spec.runtime_dependencies.map(&:name).sort
      refute(spec.files.any? { |path| path.start_with?("test/", ".superpowers/", "pkg/", "docs/superpowers/") })
    end
  end
end
