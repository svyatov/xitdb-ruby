# frozen_string_literal: true

# Development tasks for style, types, tests, and compatibility checks.
# The default task runs the repository's local quality checks.

require "bundler/setup"
require "rake/testtask"
require "rbconfig"

desc "Build the native Ruby-profile page codec for this Ruby"
task :compile do
  directory = "tmp/native/#{RUBY_ENGINE}-#{RUBY_VERSION}-#{RUBY_PLATFORM}"
  mkdir_p directory
  Dir.chdir(directory) do
    ruby File.expand_path("ext/xitdb/page_codec/extconf.rb", __dir__)
    sh RbConfig::CONFIG.fetch("MAKE", "make")
  end
  cp "#{directory}/page_codec.#{RbConfig::CONFIG.fetch("DLEXT")}", "lib/xitdb/"
end

desc "Check Ruby style"
task :rubocop do
  ruby Gem.bin_path("rubocop", "rubocop"), "--cache", "false"
end

desc "Check all library types and require 100% typed calls"
task :types do
  ruby Gem.bin_path("rbs", "rbs"), "-r", "xitdb", "validate"
  ruby Gem.bin_path("steep", "steep"), "check", "--validate=project", "-j", "2"
  ruby "script/check_type_coverage.rb"
end

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/{core,public,ruby}/**/*_test.rb"
end

desc "Run tests after building the native page codec"
task test: :compile

desc "Run tests with fresh coverage and enforce CRAP <= 10"
task :crap do
  ruby "-S", "rake", "test", "COVERAGE=1"
  ruby Gem.bin_path("crap4ruby", "crap4ruby"), "lib", "--coverage", "coverage/.resultset.json", "--threshold", "10",
       "--no-save"
end

desc "Run fast tests and the selected Go interoperability case"
task verify: :test do
  ruby "script/interop.rb", "--reference", "go", "--case", ENV.fetch("XITDB_CASE", "empty")
end

desc "Run all four pinned reference implementations (requires every toolchain)"
task interop: :compile do
  ruby "-Ilib:test", "test/interop/reference_test.rb"
  ruby "script/interop.rb", "--all"
end

desc "Run the Linux hard-memory gate (requires Docker and the cached Ruby image)"
task stress: :compile do
  ruby "-Ilib:test", "test/stress/memory_test.rb"
end

task default: %i[rubocop types crap]
