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

task default: :test
