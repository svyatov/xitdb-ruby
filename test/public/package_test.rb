# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/package_helpers"

class PackageTest < Minitest::Test
  include PackageHelpers

  def test_built_gem_loads_both_profiles_in_a_clean_bundle
    with_built_package do |spec|
      assert_equal "Ada", packaged_example("portable").fetch("name")
      assert_same true, packaged_example("ruby").fetch("enabled")
      assert_equal %w[Ada Grace], packaged_example("indexed_users").fetch("names")
      %w[README.md CHANGELOG.md LICENSE docs/core.md docs/portable.md docs/ruby.md
         docs/ruby-profile-v1.md sig/base.rbs sig/core.rbs sig/native.rbs sig/public.rbs
         sig/ruby.rbs sig/manifest.yaml].each do |path|
        assert_includes spec.files, path
      end
      assert_empty spec.extensions
      assert_equal %w[bigdecimal date], spec.runtime_dependencies.map(&:name).sort
      refute(spec.files.any? { |path| path.start_with?("test/", ".superpowers/", "pkg/", "docs/superpowers/") })
    end
  end
end
