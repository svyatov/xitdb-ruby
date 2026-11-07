# frozen_string_literal: true

# Checks native large values and packed records under a Linux hard memory limit.
require "optparse"
require_relative "../test/stress/workload"

limit = 256
OptionParser.new do |parser|
  parser.on("--limit-mib N", Integer) { |value| limit = value }
end.parse!
raise ArgumentError, "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?

reports = %w[string rows].map do |mode|
  BoundedWorkload.isolate("native-#{mode}", limit_mib: limit, data_mib: mode == "string" ? 128 : 800)
end
sources = Dir[File.expand_path("../lib/**/*.rb", __dir__)].to_h do |path|
  [path.delete_prefix("#{File.expand_path("..", __dir__)}/"), Digest::SHA256.file(path).hexdigest]
end
puts JSON.pretty_generate("cases" => reports, "library_sha256" => sources)
