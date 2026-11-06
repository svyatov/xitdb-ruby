# frozen_string_literal: true

# Instrument one public workload without installing a profiler.
require_relative "native_benchmark"
require "objspace"
require File.join(ENV.fetch("XITDB_LIBROOT", NativeBenchmark::ROOT), "lib/xitdb/ruby")

# Inclusive method costs overlap. Instrumentation changes timings and allocations.
module NativeProfile
  CPU_CLOCK = Process::CLOCK_PROCESS_CPUTIME_ID
  @active = false
  @methods = {}
  @appends = Hash.new { |hash, key| hash[key] = { calls: 0, bytes: 0 } }

  class << self
    attr_accessor :active
    attr_reader :methods, :appends

    def observe(klass, name)
      stats = @methods["#{klass}##{name}"] = { calls: 0, cpu_seconds: 0.0, allocations: 0 }
      klass.prepend(Module.new do
        define_method(name) do |*args, **kwargs, &block|
          return super(*args, **kwargs, &block) unless NativeProfile.active

          allocated = GC.stat(:total_allocated_objects)
          started = Process.clock_gettime(NativeProfile::CPU_CLOCK)
          begin
            result = super(*args, **kwargs, &block)
            if name == :checkpoint
              captured = result.slots.size
              stats[:captured_slots] = stats.fetch(:captured_slots, 0) + captured
              stats[:peak_slots] = [stats.fetch(:peak_slots, 0), captured].max
            end
            result
          ensure
            stats[:calls] += 1
            stats[:cpu_seconds] += Process.clock_gettime(NativeProfile::CPU_CLOCK) - started
            stats[:allocations] += GC.stat(:total_allocated_objects) - allocated
          end
        end
      end)
    end

    def capture
      @methods.each_value { |row| row.replace(calls: 0, cpu_seconds: 0.0, allocations: 0) }
      @appends.clear
      GC.start
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(CPU_CLOCK)
      @active = true
      yield
      { cpu_seconds: Process.clock_gettime(CPU_CLOCK) - started,
        allocations: GC.stat(:total_allocated_objects) - allocated,
        methods: Marshal.load(Marshal.dump(@methods)), appends_by_size: @appends.transform_values(&:dup) }
    ensure
      @active = false
    end

    def tail_read_control
      store = XitDB::Core::MemoryStore.new("x".b * 1_048_576)
      store.write_at(0, "y")
      GC.start
      disabled = GC.disable
      begin
        before = ObjectSpace.memsize_of_all(String)
        reads = Array.new(20) do
          result = store.read_at(store.length - 144, 144)
          store.write_at(store.length - 1, "y")
          result
        end
        allocated = ObjectSpace.memsize_of_all(String) - before
      ensure
        GC.enable unless disabled
      end
      raise "tail read snapshot changed" unless reads.first == "x" * 144 && reads.last[-1] == "y"

      { store_bytes: store.length, retained_reads: reads.size, read_bytes: 144, string_bytes_increase: allocated }
    ensure
      store&.close
    end
  end
end

XitDB::Core::Transaction.prepend(Module.new do
  def append(bytes)
    if NativeProfile.active
      stats = NativeProfile.appends[bytes.bytesize]
      stats[:calls] += 1
      stats[:bytes] += bytes.bytesize
    end
    super
  end
end)

[[XitDB::Core::Transaction, :checkpoint], [XitDB::Core::ArrayList, :initialize],
 [XitDB::Core::ArrayList, :get], [XitDB::Ruby::Containers, :publish],
 [XitDB::Ruby::Containers, :record_for], [XitDB::Ruby::Containers, :initialize],
 [XitDB::Core::Slot.singleton_class, :parse], [XitDB::Ruby::KeyEncoding.singleton_class, :dump],
 [XitDB::Ruby::Scalars.singleton_class, :encode], [XitDB::Ruby::Scalars.singleton_class, :decode],
 [XitDB::Core::HashMap, :entry], [XitDB::Core::SortedMap.const_get(:Tree), :locate],
 [XitDB::Core::CRC64.singleton_class, :call],
 [XitDB::Core::Database, :read_at]].each { |klass, name| NativeProfile.observe(klass, name) }

options = { fixture: "/Users/leonid/Projects/My/open-source/crap4ruby", store: "file" }
OptionParser.new do |parser|
  parser.on("--fixture PATH") { |value| options[:fixture] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--count N", Integer) { |value| options[:count] = value }
  parser.on("--store NAME") { |value| options[:store] = value }
end.parse!
raise ArgumentError, "store must be file or memory" unless %w[file memory].include?(options[:store])

records = NativeBenchmark.fixture(options[:fixture]).fetch(:records)
records = NativeBenchmark.dataset(records, options.fetch(:count, "fixture"))
report = { ruby: RUBY_DESCRIPTION, count: records.size, store: options[:store],
           input_sha256: Digest::SHA256.hexdigest(JSON.generate(records)), operations: {} }
Dir.mktmpdir("xitdb-native-profile") do |dir|
  database = options[:store] == "memory" ? XitDB::Ruby.memory : XitDB::Ruby.open(File.join(dir, "data.xit"))
  begin
    report[:operations][:insert] = NativeProfile.capture { database.transaction { |root| root["data"] = records } }
    report[:initial_bytes] = NativeBenchmark.size(database)
    report[:operations][:read] = NativeProfile.capture { NativeBenchmark.check!(database, records, "ruby") }
    report[:operations][:reassign] = NativeProfile.capture { database.transaction { |root| root["data"] = records } }
    report[:operations][:update] = NativeProfile.capture do
      database.transaction { |root| root["data"][records.size / 2]["complexity"] = 123 }
    end
    report[:operations][:compact] = NativeProfile.capture do
      database.compact(to: File.join(dir, "compact.xit")).close
    end
    report[:compacted_bytes] = File.size(File.join(dir, "compact.xit"))
  ensure
    database.close
  end
end
report[:tail_read_control] = NativeProfile.tail_read_control
File.write(options.fetch(:output), "#{JSON.pretty_generate(report)}\n")
