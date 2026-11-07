# frozen_string_literal: true

# Account for each copied graph record using the production compactor.
require_relative "native_benchmark"
require File.join(ENV.fetch("XITDB_LIBROOT", NativeBenchmark::ROOT), "lib/xitdb/ruby")

# Compaction already detects sharing; count only first-time reservations.
module NativeByteAccount
  def self.rows
    @rows ||= Hash.new { |hash, key| hash[key] = { count: 0, bytes: 0 } }
  end

  private

  def remap_pointer(slot)
    (@account_tags ||= {})[slot.value] = slot.tag
    super
  end

  def reserve(source, size, **, &)
    before = @transaction.length
    result = super
    if @transaction.length > before
      tag = (@account_tags || {})[source] || :untyped_block
      tag = "record_#{read(source, 4).unpack1("N")}" if tag == :record
      row = NativeByteAccount.rows[tag]
      row[:count] += 1
      row[:bytes] += size
    end
    result
  end

  def copy_bytes(slot)
    before = @transaction.length
    result = super
    if @transaction.length > before
      source = XitDB::Core::Bytes.open(@source, slot, bound: @bound)
      prefix = source.read(0, [source.size, 2].min).unpack1("H*")
      row = NativeByteAccount.rows["bytes_#{source.format_tag}_#{prefix}"]
      row[:count] += 1
      row[:bytes] += @transaction.length - before
    end
    result
  end
end

options = { fixture: "/Users/leonid/Projects/My/open-source/crap4ruby", count: "10000", store: "memory" }
OptionParser.new do |parser|
  parser.on("--fixture PATH") { |value| options[:fixture] = value }
  parser.on("--count COUNT") { |value| options[:count] = value }
  parser.on("--store STORE") { |value| options[:store] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!
raise ArgumentError, "unknown store" unless %w[memory file].include?(options[:store])

XitDB::Core::Compaction.prepend(NativeByteAccount)
fixture = NativeBenchmark.fixture(options[:fixture])
records = NativeBenchmark.dataset(fixture.fetch(:records), options[:count])
Dir.mktmpdir("xitdb-native-account") do |directory|
  database = if options[:store] == "memory"
               XitDB::Ruby.memory
             else
               XitDB::Ruby.open(File.join(directory, "source.xit"))
             end
  database.transaction { |root| root["data"] = records }
  database.transaction { |root| root["data"][records.size / 2]["complexity"] = 123 }
  10.times { |index| database.transaction { |root| root["revision"] = index } }
  compacted = database.compact(to: File.join(directory, "compact.xit"))
  expected = records.map.with_index { |row, index| index == records.size / 2 ? row.merge("complexity" => 123) : row }
  NativeBenchmark.check!(compacted, expected, "ruby")
  bytes = NativeBenchmark.size(compacted)
  library = ENV.fetch("XITDB_LIBROOT", NativeBenchmark::ROOT)
  report = { ruby: RUBY_DESCRIPTION, count: records.size, store: options[:store], compacted_bytes: bytes,
             graph: NativeByteAccount.rows,
             file_and_history_overhead: bytes - NativeByteAccount.rows.values.sum { |row| row[:bytes] },
             input_sha256: Digest::SHA256.hexdigest(JSON.generate(records)),
             driver_sha256: Digest::SHA256.file(__FILE__).hexdigest,
             library_sha256: Dir[File.join(library, "lib/**/*.rb")].to_h do |path|
               [path.split("/lib/").last, Digest::SHA256.file(path).hexdigest]
             end }
  File.write(options.fetch(:output), "#{JSON.pretty_generate(report)}\n")
ensure
  compacted&.close
  database&.close
end
