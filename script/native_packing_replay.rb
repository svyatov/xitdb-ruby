# frozen_string_literal: true

# Replays one archived representation probe with its measured library and fixture.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"
require "zlib"

options = { variant: "selected", count: "fixture", store: "memory", layout: "ruby" }
OptionParser.new do |parser|
  parser.on("--variant NAME") { |value| options[:variant] = value }
  parser.on("--count N") { |value| options[:count] = value }
  parser.on("--store NAME") { |value| options[:store] = value }
  parser.on("--layout NAME") { |value| options[:layout] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!
variants = { "optimized" => "optimized", "indexed" => "prototype", "builder" => "prototype",
             "shared" => "prototype", "schema" => "schema-copy", "checked" => "checked-copy",
             "values" => "values-copy", "frozen" => "frozen-copy", "selected" => "trusted-copy" }.freeze
library = variants.fetch(options[:variant])
raise ArgumentError, "store must be memory or file" unless %w[memory file].include?(options[:store])
raise ArgumentError, "layout must be ruby, portable, or json" unless %w[ruby portable json].include?(options[:layout])

output = File.expand_path(options.fetch(:output))
raise ArgumentError, "output already exists" if File.exist?(output)

root = File.expand_path("..", __dir__)
directory = File.join(root, "docs/benchmarks/native-records")
source = File.join(directory, "packing-prototype-sources.json.gz")
manifest = JSON.parse(File.read(File.join(directory, "packing-provenance.json")))
expected = manifest.fetch("artifacts").fetch(File.basename(source))
raise "archive digest mismatch" unless Digest::SHA256.file(source).hexdigest == expected

archive = Zlib::GzipReader.open(source) { |file| JSON.parse(file.read) }
Dir.mktmpdir("xitdb-packing-replay") do |dir|
  rewrite = lambda do |text|
    text.gsub("/Users/leonid/Projects/My/open-source/xitdb-ruby", dir).gsub("/tmp/", "#{dir}/")
  end
  FileUtils.mkdir_p(File.join(dir, "script"))
  File.write(File.join(dir, "script/native_benchmark.rb"), archive.fetch("benchmark_source"))
  archive.fetch("scripts").each do |name, text|
    File.write(File.join(dir, name), rewrite.call(text))
  end
  libroot = File.join(dir, "xitdb-packed-#{library}")
  archive.fetch("libraries").fetch(library).each do |name, text|
    path = File.join(libroot, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, rewrite.call(text))
  end
  input = File.join(dir, "input.marshal")
  File.binwrite(input, archive.fetch("fixture_marshal_base64").unpack1("m0"))
  environment = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
  sharing = %w[shared schema checked values frozen selected].include?(options[:variant])
  environment = environment.merge("XITDB_LIBROOT" => libroot, "RUBYOPT" => nil,
                                  "XITDB_PACKED_OUTPUT" => nil,
                                  "XITDB_PACKED_KEYS" => sharing ? "1" : nil,
                                  "XITDB_PACKED_ARRAY_BUILDER" => options[:variant] == "indexed" ? "0" : "1")
  json, status = Open3.capture2(environment, RbConfig.ruby, File.join(dir, "xitdb-packed-worker.rb"), input,
                                options[:count], options[:store], options[:layout], unsetenv_others: true)
  raise "replay failed: #{json}" unless status.success?

  result = JSON.parse(json).merge("variant" => options[:variant], "dataset" => options[:count],
                                  "store" => options[:store], "layout" => options[:layout],
                                  "archive_sha256" => expected)
  File.write(output, "#{JSON.pretty_generate(result)}\n")
end
puts output
