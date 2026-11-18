# frozen_string_literal: true

# Replays an archived storage experiment, including its measured library.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"
require "zlib"

options = { stage: "final", variant: "typed:1024", count: "10000", store: "file" }
OptionParser.new do |parser|
  parser.on("--stage NAME") { |value| options[:stage] = value }
  parser.on("--variant NAME") { |value| options[:variant] = value }
  parser.on("--count N") { |value| options[:count] = value }
  parser.on("--store NAME") { |value| options[:store] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!
raise ArgumentError, "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?
raise ArgumentError, "store must be memory or file" unless %w[memory file].include?(options[:store])
unless options[:count] == "fixture" || /\A[1-9][0-9]*\z/.match?(options[:count])
  raise ArgumentError, "count must be fixture or a positive integer"
end

output = File.expand_path(options.fetch(:output))
raise ArgumentError, "output already exists" if File.exist?(output)

directory = File.expand_path("../docs/benchmarks/native-pages", __dir__)
manifest = JSON.parse(File.read(File.join(directory, "provenance.json")))
source = File.join(directory, "sources.json.gz")
digest = manifest.fetch("artifacts").fetch(File.basename(source))
raise "source digest mismatch" unless Digest::SHA256.file(source).hexdigest == digest

archive = Zlib::GzipReader.open(source) { |file| JSON.parse(file.read) }
sources = archive.fetch("stages").fetch(options[:stage])
samples_path = File.join(directory, "#{options[:stage]}-samples.json.gz")
expected = manifest.fetch("artifacts").fetch(File.basename(samples_path))
raise "samples digest mismatch" unless Digest::SHA256.file(samples_path).hexdigest == expected

samples = Zlib::GzipReader.open(samples_path) { |file| JSON.parse(file.read) }
variants = samples.fetch("results").map { |row| row.fetch("variant") }.uniq
unless variants.include?(options[:variant])
  raise ArgumentError, "variant must be recorded in #{options[:stage]}: #{variants.join(", ")}"
end

layout, width, guard = options[:variant].split(":")

Dir.mktmpdir("xitdb-page-replay") do |dir|
  archive.fetch("library").merge("script/native_benchmark.rb" => archive.fetch("benchmark_source"))
         .merge(sources).each do |name, text|
    path = File.expand_path(name, dir)
    raise "archive path outside scratch directory" unless path.start_with?("#{dir}/")

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
  environment = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
  environment = environment.merge("XITDB_PROBE_ROOT" => dir, "XITDB_LIBROOT" => dir, "RUBYOPT" => nil,
                                  "PAGE_GUARD_SCAN" => nil)
  if sources.key?("extconf.rb")
    raise "extension configuration failed" unless system(environment, RbConfig.ruby, "extconf.rb", chdir: dir)
    raise "extension build failed" unless system(environment, "make", chdir: dir)
  end
  input = File.join(dir, "input.marshal")
  File.binwrite(input, archive.fetch("fixture_marshal_base64").unpack1("m0"))
  command = if %w[ruby json].include?(layout)
              [File.join(dir, "script/native_benchmark.rb"), "--worker", input,
               options[:count], options[:store], layout]
            elsif layout == "ruby_native_guard"
              [File.join(dir, "probe.rb"), "--native-worker", input, options[:count], options[:store]]
            else
              [File.join(dir, "probe.rb"), "--worker", input, options[:count], options[:store], layout,
               width || "256", guard.to_s]
            end
  json, status = Open3.capture2(environment, RbConfig.ruby, *command, unsetenv_others: true)
  raise "replay failed: #{json}" unless status.success?

  result = JSON.parse(json).merge("stage" => options[:stage], "variant" => options[:variant],
                                  "dataset" => options[:count], "store" => options[:store], "archive_sha256" => digest)
  File.write(output, "#{JSON.pretty_generate(result)}\n")
end
puts output
