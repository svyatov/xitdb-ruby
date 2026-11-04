# frozen_string_literal: true

require_relative "lib/xitdb/version"

Gem::Specification.new do |spec|
  spec.name = "xitdb"
  spec.version = XitDB::VERSION
  spec.authors = ["Leonid Svyatov"]
  spec.summary = "Pure Ruby implementation of xitdb"
  spec.homepage = "https://github.com/svyatov/xitdb-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "LICENSE"]
  spec.require_paths = ["lib"]
end
