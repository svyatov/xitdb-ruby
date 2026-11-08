# frozen_string_literal: true

# Replays the public API page experiment against its archived library.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"
require "zlib"

options = { study: "adapters", variant: "pages", count: "10000", store: "file", check: false }
OptionParser.new do |parser|
  parser.on("--study NAME") { |value| options[:study] = value }
  parser.on("--variant NAME") { |value| options[:variant] = value }
  parser.on("--count N") { |value| options[:count] = value }
  parser.on("--store NAME") { |value| options[:store] = value }
  parser.on("--check") { options[:check] = true }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!
raise ArgumentError, "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?
raise ArgumentError, "study must be adapters or decode" unless %w[adapters decode].include?(options[:study])

variants = %w[pages json ruby guarded]
variants << "core_json" if options[:study] == "decode"
raise ArgumentError, "variant must be one of: #{variants.join(", ")}" unless variants.include?(options[:variant])
raise ArgumentError, "store must be memory or file" unless %w[memory file].include?(options[:store])
raise ArgumentError, "count must be a positive integer" unless /\A[1-9][0-9]*\z/.match?(options[:count])

output = File.expand_path(options.fetch(:output))
raise ArgumentError, "output already exists" if File.exist?(output) || File.symlink?(output)

directory = File.expand_path("../docs/benchmarks/native-#{options[:study]}", __dir__)
manifest = JSON.parse(File.read(File.join(directory, "provenance.json")))
source = File.join(directory, "sources.json.gz")
digest = manifest.fetch("artifacts").fetch(File.basename(source))
raise "source digest mismatch" unless Digest::SHA256.file(source).hexdigest == digest

archive = Zlib::GzipReader.open(source) { |file| JSON.parse(file.read) }
Dir.mktmpdir("xitdb-adapter-replay") do |dir|
  archive.fetch("library").merge(archive.fetch("sources")).each do |name, text|
    path = File.expand_path(name, dir)
    raise "archive path outside scratch directory" unless path.start_with?("#{dir}/")

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
  environment = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
  environment = environment.merge("XITDB_PROBE_ROOT" => dir, "RUBYOPT" => nil, "ADAPTER" => "1")
  build = []
  if options[:check] || %w[pages guarded].include?(options[:variant])
    [[RbConfig.ruby, "extconf.rb"], ["make"]].each do |command|
      log, status = Open3.capture2e(environment, *command, chdir: dir, unsetenv_others: true)
      raise "extension build failed: #{log}" unless status.success?

      build << log
    end
  end
  command = if options[:check]
              ["-I#{dir}/lib", File.join(dir, "contract_test.rb")]
            elsif options[:variant] == "core_json"
              [File.join(dir, "core_worker.rb"), options[:store], options[:count]]
            else
              [File.join(dir, "worker.rb"), options[:variant], options[:store], options[:count]]
            end
  stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, *command, unsetenv_others: true)
  raise "replay failed: #{stderr}\n#{stdout}" unless status.success?

  result = options[:check] ? { "checks" => stdout } : JSON.parse(stdout)
  result.merge!("archive_sha256" => digest, "ruby" => RUBY_DESCRIPTION, "build" => build)
  File.open(output, "wx", 0o600) { |file| file.write("#{JSON.pretty_generate(result)}\n") }
end
puts output
