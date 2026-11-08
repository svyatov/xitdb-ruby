# frozen_string_literal: true

# Package metadata and the explicit file list shipped to gem users.
# Development tools are declared in Gemfile rather than runtime dependencies.

require_relative "lib/xitdb/version"

Gem::Specification.new do |spec|
  spec.name = "xitdb"
  spec.version = XitDB::VERSION
  spec.authors = ["Leonid Svyatov"]
  spec.summary = "Pure Ruby implementation of xitdb"
  spec.description = "Transactional collections, portable xitdb storage, and an explicit Ruby value profile."
  spec.homepage = "https://github.com/svyatov/xitdb-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "sig/manifest.yaml", "examples/*.rb", "README.md", "CHANGELOG.md",
                   "LICENSE", "docs/*.md"]
  spec.require_paths = ["lib"]
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.add_dependency "bigdecimal", ">= 3.1"
  spec.add_dependency "date", ">= 3.3"
  spec.metadata["rubygems_mfa_required"] = "true"
end
