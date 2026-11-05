# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/{core,public,ruby}/**/*_test.rb"
end

desc "Run fast tests and the selected Go interoperability case"
task verify: :test do
  ruby "script/interop.rb", "--reference", "go", "--case", ENV.fetch("XITDB_CASE", "empty")
end

desc "Run all four pinned reference implementations (requires every toolchain)"
task :interop do
  ruby "-Ilib:test", "test/interop/reference_test.rb"
  ruby "script/interop.rb", "--all"
end

desc "Run the Linux hard-memory gate (requires Docker and the cached Ruby image)"
task :stress do
  ruby "-Ilib:test", "test/stress/memory_test.rb"
end

task default: :test
