# frozen_string_literal: true

require "rbconfig"

root = File.expand_path("..", __dir__)
Dir.chdir(root) do
  puts RUBY_DESCRIPTION
  $stdout.flush
  # PackageTest builds and installs the gem locally, checks its file list and
  # runtime dependencies, and runs every example through an isolated bundle.
  abort "Quality checks or package inspection failed" unless system(RbConfig.ruby, Gem.bin_path("rake", "rake"))
  puts "Style, types, tests, CRAP scores, packaged examples, and gem inspection passed"
end
