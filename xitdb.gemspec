# frozen_string_literal: true

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
  spec.add_dependency "bigdecimal", ">= 3.1"
  spec.add_dependency "date", ">= 3.3"
  spec.metadata["rubygems_mfa_required"] = "true"
end
