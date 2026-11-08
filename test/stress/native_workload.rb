# frozen_string_literal: true

# Exercises native records and oversized scalar encoding under Linux memory limits.
module NativeWorkload
  MIB = 1024 * 1024
  ROWS = 12_500

  # Checks native String bytes through bounded sources without materialization.
  def self.check_stream!(database, view, key, size, digest)
    slot = view.adapter.lookup(key)
    source, encoding = database.profile.conversion_bytes(slot, context: view.context)
    raise "native stream metadata mismatch" unless source.size == size && encoding == Encoding::BINARY

    actual = Digest::SHA256.new
    position = 0
    while position < size
      piece = source.read(position, [65_536, size - position].min)
      actual.update(piece)
      position += piece.bytesize
    end
    raise "native stream digest mismatch" unless actual.hexdigest == digest
  end

  # Stores a caller-owned 128 MiB String and retains it across compaction.
  def self.string(database, path)
    payload = "0123456789abcdef".b * (128 * MIB / 16)
    size = payload.bytesize
    digest = Digest::SHA256.hexdigest(payload)
    old = database.transaction do |root|
      root["blob"] = payload
      root["revision"] = 0
    end
    report = { "input_bytes" => size, "file_bytes" => File.size(path), "sha256" => digest }
    check_stream!(database, old, "blob", size, digest)
    database.transaction { |root| root["revision"] = 1 }
    check_stream!(database, old, "blob", size, digest)
    payload = nil
    GC.start
    [report, old, size, digest]
  end

  # Stores more than 768 MiB while keeping one 64 KiB source String in memory.
  def self.rows(database, path)
    shared = "0123456789abcdef".b * 4096
    digest = Digest::SHA256.hexdigest(shared)
    records = Array.new(ROWS) do |index|
      { "name" => "method_#{index}", "path" => "lib/sample.rb", "complexity" => index, "payload" => shared }
    end
    old = database.transaction { |root| root["rows"] = records }
    report = { "rows" => ROWS, "payload_bytes" => shared.bytesize, "file_bytes" => File.size(path) }
    raise "native fixture is below 768 MiB" unless report.fetch("file_bytes") > 768 * MIB

    before = File.size(path)
    database.transaction { |root| root["rows"][ROWS / 2]["complexity"] = -1 }
    report["update_growth_bytes"] = File.size(path) - before
    raise "native update exceeded bounded path" unless report.fetch("update_growth_bytes") < 8192

    [0, ROWS / 2, ROWS - 1].each do |index|
      row = database.snapshot["rows"][index]
      expected = index == ROWS / 2 ? -1 : index
      raise "native indexed value mismatch" unless row["name"] == "method_#{index}" && row["complexity"] == expected

      check_stream!(database, row, "payload", shared.bytesize, digest)
    end
    raise "native old snapshot changed" unless old["rows"][ROWS / 2]["complexity"] == ROWS / 2

    records = nil
    shared = nil
    GC.start
    [report, old, 65_536, digest]
  end

  # Verifies selective reads, snapshots, reopen, and bounded compaction.
  def self.run(mode, directory)
    path = File.join(directory, "native-source.xit")
    destination = File.join(directory, "native-compact.xit")
    compacted = nil
    report = nil
    XitDB::Ruby.open(path) do |database|
      report, old, size, digest = mode == "string" ? string(database, path) : rows(database, path)
      compacted = database.compact(to: destination)
      report["compacted_bytes"] = File.size(destination)
      report["offset_cache_peak_entries"] = BoundedWorkload::OffsetPeak.entries
      if report.fetch("offset_cache_peak_entries") > XitDB::Core::OffsetMap::CACHE_LIMIT
        raise "native offset cache exceeded bound"
      end

      if mode == "string"
        check_stream!(compacted, compacted.snapshot, "blob", size, digest)
        database.transaction { |root| root["blob"] = "replacement" }
        check_stream!(database, old, "blob", size, digest)
      else
        raise "compacted native row mismatch" unless compacted.snapshot["rows"][ROWS / 2]["complexity"] == -1
        raise "old native row changed after compaction" unless old["rows"][ROWS / 2]["complexity"] == ROWS / 2

        check_stream!(compacted, compacted.snapshot["rows"][ROWS - 1], "payload", size, digest)
      end
    end
    XitDB::Ruby.open(path) do |database|
      actual = mode == "string" ? database.snapshot["blob"] : database.snapshot["rows"][ROWS / 2]["complexity"]
      raise "native reopen mismatch" unless actual == (mode == "string" ? "replacement" : -1)
    end
    report.merge("mode" => mode, "status" => "passed")
  ensure
    compacted&.close
    [path, destination].each { |file| FileUtils.rm_f(file) }
  end
end
