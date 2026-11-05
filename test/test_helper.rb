# frozen_string_literal: true

# Loads Minitest and the public gem entry point.
# Set COVERAGE to collect library line and branch coverage with SimpleCov.

if ENV["COVERAGE"]
  require "simplecov"
  File.delete("coverage/.resultset.json") if File.file?("coverage/.resultset.json")
  SimpleCov.start do
    cover "lib/**/*.rb"
    enable_coverage :branch
  end
end

require "minitest/autorun"
require "xitdb"
