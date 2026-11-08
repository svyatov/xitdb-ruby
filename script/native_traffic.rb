# frozen_string_literal: true

# Instrument store API traffic separately from the uninstrumented timing matrix.
require_relative "native_benchmark"

# Counts requested logical bytes, including temporary maintenance stores.
module NativeTraffic
  class << self
    attr_accessor :read_bytes, :written_bytes, :reads, :writes

    def reset
      self.read_bytes = self.written_bytes = self.reads = self.writes = 0
    end

    def sample
      { read_bytes: read_bytes, written_bytes: written_bytes, reads: reads, writes: writes }
    end
  end

  def read_at(offset, length)
    NativeTraffic.read_bytes += length
    NativeTraffic.reads += 1
    super
  end

  def write_at(offset, bytes)
    NativeTraffic.written_bytes += bytes.bytesize
    NativeTraffic.writes += 1
    super
  end

  # Retains the worker's correctness checks and operation boundaries.
  module Measurement
    def measure(operation, &)
      if operation != "load" && !@traffic_installed
        XitDB::Core.const_get(:Store).prepend(NativeTraffic)
        @traffic_installed = true
      end
      NativeTraffic.reset
      sample, result = super
      sample[:store_traffic] = NativeTraffic.sample unless operation == "load"
      [sample, result]
    end
  end
end

if ARGV.first == "--worker"
  ARGV.shift
  NativeBenchmark.singleton_class.prepend(NativeTraffic::Measurement)
  puts JSON.generate(NativeBenchmark.worker(*ARGV))
  exit
end

options = { fixture: "/Users/leonid/Projects/My/open-source/crap4ruby", count: "fixture",
            store: "file", layout: "ruby" }
OptionParser.new do |parser|
  parser.on("--fixture PATH") { |value| options[:fixture] = value }
  parser.on("--count COUNT") { |value| options[:count] = value }
  parser.on("--store STORE") { |value| options[:store] = value }
  parser.on("--layout LAYOUT") { |value| options[:layout] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!
raise ArgumentError, "unknown store" unless %w[memory file].include?(options[:store])
raise ArgumentError, "unknown layout" unless %w[ruby portable json].include?(options[:layout])

Dir.mktmpdir("xitdb-native-traffic") do |directory|
  input = File.join(directory, "input.marshal")
  File.binwrite(input, Marshal.dump(NativeBenchmark.fixture(options[:fixture])))
  environment = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
  library = ENV.fetch("XITDB_LIBROOT", NativeBenchmark::ROOT)
  environment = environment.merge("XITDB_LIBROOT" => library, "RUBYOPT" => nil)
  output, status = Open3.capture2(environment, RbConfig.ruby, __FILE__, "--worker", input,
                                  options[:count], options[:store], options[:layout], unsetenv_others: true)
  raise "traffic worker failed: #{output}" unless status.success?

  result = JSON.parse(output)
  result[:instrumentation] = "logical store API traffic, includes temporary stores; timings are instrumented"
  result[:driver_sha256] = Digest::SHA256.file(__FILE__).hexdigest
  File.write(options.fetch(:output), "#{JSON.pretty_generate(result)}\n")
end
