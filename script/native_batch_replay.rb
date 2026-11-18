# frozen_string_literal: true

# Replays compiled rb02 experiments with their archived Ruby library.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"
require "zlib"

variants = { "ruby" => %w[0 0 0 ruby], "json" => %w[0 0 0 json], "batch" => %w[1 1 1 ruby],
             "encode" => %w[1 0 0 ruby], "decode" => %w[0 1 0 ruby], "decode_cached" => %w[0 1 1 ruby] }
options = { stage: "optimized", variant: "batch", count: "10000", store: "file" }
OptionParser.new do |parser|
  parser.on("--stage NAME") { |value| options[:stage] = value }
  parser.on("--variant NAME") { |value| options[:variant] = value }
  parser.on("--count N") { |value| options[:count] = value }
  parser.on("--store NAME") { |value| options[:store] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--check") { options[:check] = true }
end.parse!
raise ArgumentError, "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?
raise ArgumentError, "store must be memory or file" unless %w[memory file].include?(options[:store])
unless options[:count] == "fixture" || /\A[1-9][0-9]*\z/.match?(options[:count])
  raise ArgumentError, "count must be fixture or a positive integer"
end

encode, decode, cache, layout = variants.fetch(options[:variant])
output = File.expand_path(options.fetch(:output))
raise ArgumentError, "output already exists" if File.exist?(output)

directory = File.expand_path("../docs/benchmarks/native-batch", __dir__)
manifest = JSON.parse(File.read(File.join(directory, "provenance.json")))
source = File.join(directory, "sources.json.gz")
digest = manifest.fetch("artifacts").fetch(File.basename(source))
raise "source digest mismatch" unless Digest::SHA256.file(source).hexdigest == digest

archive = Zlib::GzipReader.open(source) { |file| JSON.parse(file.read) }
sources = archive.fetch("stages").fetch(options[:stage])
Dir.mktmpdir("xitdb-batch-replay") do |dir|
  archive.fetch("library").merge("script/native_benchmark.rb" => archive.fetch("benchmark_source"))
         .merge(sources).each do |name, text|
    path = File.expand_path(name, dir)
    raise "archive path outside scratch directory" unless path.start_with?("#{dir}/")

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
  environment = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
  environment = environment.merge("XITDB_LIBROOT" => dir, "RUBYOPT" => nil,
                                  "BATCH_ENCODE" => encode, "BATCH_DECODE" => decode, "BATCH_CACHE" => cache)
  raise "extension configuration failed" unless system(environment, RbConfig.ruby, "extconf.rb", chdir: dir)
  raise "extension build failed" unless system(environment, "make", chdir: dir)

  input = File.join(dir, "input.marshal")
  File.binwrite(input, archive.fetch("fixture_marshal_base64").unpack1("m0"))
  command = if options[:check]
              [File.join(dir, "contract.rb")]
            else
              [File.join(dir, "worker.rb"), input, options[:count], options[:store], layout]
            end
  json, status = Open3.capture2(environment, RbConfig.ruby, *command, unsetenv_others: true)
  raise "replay failed: #{json}" unless status.success?

  result = JSON.parse(json).merge("stage" => options[:stage], "archive_sha256" => digest,
                                  "mode" => options[:check] ? "checks" : "benchmark")
  unless options[:check]
    result.merge!("variant" => options[:variant], "dataset" => options[:count], "store" => options[:store])
    result["correctness"] = result.fetch("correctness").delete_suffix(", reopen") if options[:store] == "memory"
  end
  File.write(output, "#{JSON.pretty_generate(result)}\n", mode: "wx")
end
puts output
