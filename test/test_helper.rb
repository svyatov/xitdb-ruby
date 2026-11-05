# frozen_string_literal: true

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
