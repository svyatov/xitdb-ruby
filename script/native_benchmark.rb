# frozen_string_literal: true

# Compare rb01 collections with a fixed revision. Each worker owns its database.
require "json"
require "digest"
require "tmpdir"
require "optparse"
require "open3"
require "rbconfig"
require "fileutils"

# Runs isolated workers in alternating revision order and retains every sample.
module NativeBenchmark
  CLOCK = Process::CLOCK_MONOTONIC
  ROOT = File.expand_path("..", __dir__)

  def self.measure
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(CLOCK)
    result = yield
    [{ seconds: Process.clock_gettime(CLOCK) - started,
       allocations: GC.stat(:total_allocated_objects) - allocated }, result]
  end

  def self.fixture(path)
    require File.join(path, "lib/crap4ruby")
    hashes = {}
    records = Dir.chdir(path) do
      Dir["lib/**/*.rb", sort: true].flat_map do |name|
        source = File.binread(name)
        hashes[name] = Digest::SHA256.hexdigest(source)
        Crap4Ruby::Analyzer.new.call(source, path: name).map do |method|
          { "name" => method.name, "namespace" => method.namespace, "path" => method.path,
            "complexity" => method.complexity, "coverage" => nil, "crap" => nil }
        end
      end
    end
    { records: records, files: hashes, revision: Open3.capture2("git", "-C", path, "rev-parse", "HEAD").first.strip }
  end

  def self.dataset(records, count)
    return records if count == "fixture"

    Array.new(Integer(count)) do |index|
      { "name" => "method_#{index}", "namespace" => "Example#{index % 17}",
        "path" => "lib/example_#{index % 11}.rb", "complexity" => (index % 20) + 1,
        "coverage" => nil, "crap" => nil }
    end
  end

  def self.size(database)
    database.core.root_cursor.bound
  end

  def self.check!(database, expected, layout, snapshot: database.snapshot)
    actual = snapshot["data"]
    actual = layout == "json" ? JSON.parse(actual) : actual.to_ruby
    raise "roundtrip mismatch" unless actual == expected

    return unless layout == "ruby"

    actual.zip(expected).each do |row, original|
      raise "key order mismatch" unless row.keys == original.keys

      row.each do |key, value|
        next unless value.is_a?(String)

        raise "String encoding mismatch" unless value.encoding == original.fetch(key).encoding
      end
    end
  end

  def self.worker(input, count, store, layout)
    libroot = ENV.fetch("XITDB_LIBROOT")
    loading, = measure { require File.join(libroot, layout == "ruby" ? "lib/xitdb/ruby" : "lib/xitdb") }
    # The parent owns this file. Marshal retains String encodings across workers.
    # rubocop:disable-next Security/MarshalLoad -- The parent owns this fixture in its private temporary directory.
    records = dataset(Marshal.load(File.binread(input)).fetch(:records), count)
    result = { loading: loading, count: records.size, input_sha256: Digest::SHA256.hexdigest(JSON.generate(records)),
               ruby_input_sha256: Digest::SHA256.hexdigest(Marshal.dump(records)),
               json_bytes: JSON.generate(records).bytesize, operations: {},
               library_sha256: Dir[File.join(libroot, "lib/**/*.rb")].to_h do |name|
                 [name.delete_prefix("#{libroot}/"), Digest::SHA256.file(name).hexdigest]
               end }
    Dir.mktmpdir("xitdb-native-worker") do |dir|
      path = File.join(dir, "source.xit")
      factory = layout == "ruby" ? XitDB::Ruby : XitDB
      database = store == "file" ? factory.open(path) : factory.memory
      operations = result[:operations]
      operations[:insert], = measure do
        database.transaction { |root| root["data"] = layout == "json" ? JSON.generate(records) : records }
      end
      result[:initial_bytes] = size(database)
      original = database.snapshot
      check!(database, records, layout, snapshot: original)
      operations[:read], = measure { check!(database, records, layout) }
      operations[:indexed], = measure do
        data = database.snapshot["data"]
        data = JSON.parse(data) if layout == "json"
        [0, records.size / 2, records.size - 1].each do |index|
          row = data[index]
          row = row.to_ruby unless layout == "json"
          raise "indexed mismatch" unless row == records[index]
        end
      end
      if store == "file"
        database.close
        operations[:reopen], database = measure { factory.open(path) }
        operations[:reopened_read], = measure { check!(database, records, layout) }
        original = database.history[0]
      end
      operations[:reassign], = measure do
        database.transaction { |root| root["data"] = layout == "json" ? JSON.generate(records) : records }
      end
      result[:reassign_bytes] = size(database)
      check!(database, records, layout)
      updated = records.map(&:dup)
      updated[records.size / 2]["complexity"] = 123
      operations[:update], = measure do
        database.transaction do |root|
          if layout == "json"
            data = JSON.parse(root["data"])
            data[records.size / 2]["complexity"] = 123
            root["data"] = JSON.generate(data)
          else
            root["data"][records.size / 2]["complexity"] = 123
          end
        end
      end
      result[:update_bytes] = size(database)
      check!(database, updated, layout)
      check!(database, records, layout, snapshot: original)
      operations[:commits], = measure do
        10.times { |index| database.transaction { |root| root["revision"] = index } }
      end
      result[:history_bytes] = size(database)
      result[:histories] = database.history.size
      check!(database, updated, layout)
      check!(database, records, layout, snapshot: original)
      operations[:compact], compacted = measure { database.compact(to: File.join(dir, "compact.xit")) }
      result[:compacted_bytes] = size(compacted)
      check!(compacted, updated, layout)
      raise "compaction retained old histories" unless compacted.history.size == 1

      compacted.close
      database.close
      factory.open(path) { |reopened| check!(reopened, updated, layout) } if store == "file"
      result[:correctness] = "roundtrip, indexed reads, earlier snapshot, compacted latest, reopen"
    ensure
      compacted&.close unless compacted&.closed?
      database&.close unless database&.closed?
    end
    result
  end

  def self.run(options)
    raise ArgumentError, "samples must be positive" unless options[:samples].positive?
    raise ArgumentError, "warmups must be nonnegative" if options[:warmups].negative?

    fixture = fixture(options.fetch(:fixture))
    FileUtils.mkdir_p(File.dirname(options.fetch(:output)))
    revision, status = Open3.capture2("git", "rev-parse", options.fetch(:baseline))
    raise "baseline revision does not exist" unless status.success?

    report = { baseline: revision.strip, candidate: Open3.capture2("git", "rev-parse", "HEAD").first.strip,
               ruby: RUBY_DESCRIPTION, platform: RbConfig::CONFIG["host"], samples: options[:samples],
               warmups: options[:warmups], os_cache_control: "unavailable", fixture: fixture.except(:records),
               results: [] }
    Dir.mktmpdir("xitdb-native-compare") do |dir|
      input = File.join(dir, "input.marshal")
      File.binwrite(input, Marshal.dump(fixture))
      baseline = File.join(dir, "baseline")
      FileUtils.mkdir_p(baseline)
      archive, status = Open3.capture2("git", "archive", options[:baseline])
      raise "git archive failed" unless status.success?

      archive_path = File.join(dir, "baseline.tar")
      File.binwrite(archive_path, archive)
      raise "extract failed" unless system("tar", "-xf", archive_path, "-C", baseline)

      options[:counts].product(options[:stores], options[:layouts]).each do |count, store, layout|
        (-options[:warmups]...options[:samples]).each do |sample|
          order = sample.even? ? %w[baseline candidate] : %w[candidate baseline]
          order.each do |variant|
            libroot = variant == "baseline" ? baseline : ROOT
            environment = { "XITDB_LIBROOT" => libroot, "RUBYOPT" => nil }
            output, error, status = Open3.capture3(environment, RbConfig.ruby, __FILE__,
                                                   "--worker", input, count, store, layout)
            raise "worker failed: #{error}\n#{output}" unless status.success?

            row = JSON.parse(output).merge("variant" => variant, "dataset" => count, "store" => store,
                                           "layout" => layout, "sample" => sample, "warmup" => sample.negative?)
            report[:results] << row
            File.write(options[:output], "#{JSON.pretty_generate(report)}\n")
            warn "#{variant} #{count} #{store} #{layout} sample=#{sample} insert=#{row.dig("operations", "insert",
                                                                                           "seconds").round(3)}s"
          end
        end
      end
    end
  end
end

if $PROGRAM_NAME != __FILE__
  # Profiling tools reuse fixture generation without starting the comparison.
elsif ARGV.first == "--worker"
  ARGV.shift
  puts JSON.generate(NativeBenchmark.worker(*ARGV))
else
  options = { fixture: "/Users/leonid/Projects/My/open-source/crap4ruby", samples: 7, warmups: 1,
              counts: %w[fixture 1000 10000], stores: %w[memory file], layouts: %w[ruby portable json] }
  OptionParser.new do |parser|
    parser.on("--baseline REV") { |value| options[:baseline] = value }
    parser.on("--fixture PATH") { |value| options[:fixture] = value }
    parser.on("--output PATH") { |value| options[:output] = value }
    parser.on("--samples N", Integer) { |value| options[:samples] = value }
    parser.on("--warmups N", Integer) { |value| options[:warmups] = value }
    parser.on("--counts LIST") { |value| options[:counts] = value.split(",") }
    parser.on("--stores LIST") { |value| options[:stores] = value.split(",") }
    parser.on("--layouts LIST") { |value| options[:layouts] = value.split(",") }
  end.parse!
  NativeBenchmark.run(options)
end
