# frozen_string_literal: true

# Runs isolated benchmark workloads with a 256 MiB memory limit.
# Use --output PATH to save the JSON report.

require "optparse"
require_relative "../test/stress/workload"

output = nil
OptionParser.new do |parser|
  parser.banner = "Usage: ruby script/benchmark.rb --output PATH"
  parser.on("--output PATH") { |value| output = value }
end.parse!
raise ArgumentError, "--output is required" unless output && ARGV.empty?

report = BoundedWorkload.isolate("benchmark", limit_mib: 256)
FileUtils.mkdir_p(File.dirname(output))
File.write(output, "#{JSON.pretty_generate(report)}\n")
puts output
