# frozen_string_literal: true

# Copies a disposable Ruby runtime before starting the memory-limited container.
require "fileutils"

raise ArgumentError, "usage: ruby script/stress_build.rb DESTINATION" unless ARGV.size == 1

destination = File.expand_path(ARGV.fetch(0))
raise ArgumentError, "destination already exists" if File.exist?(destination)

root = File.expand_path("..", __dir__)
Dir.chdir(root) do
  Dir["lib/**/*.rb", "test/stress/*.rb"].each do |source|
    target = File.join(destination, source)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(source, target)
  end
end
