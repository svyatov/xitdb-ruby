# frozen_string_literal: true

require "optparse"
require_relative "../test/stress/workload"

options = { limit_mib: 256, data_mib: 768 }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby script/stress.rb --limit-mib 256 --data-mib 768"
  parser.on("--limit-mib N", Integer) { |value| options[:limit_mib] = value }
  parser.on("--data-mib N", Integer) { |value| options[:data_mib] = value }
end.parse!
raise ArgumentError, "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?

puts JSON.pretty_generate(BoundedWorkload.isolate("stress", **options))
