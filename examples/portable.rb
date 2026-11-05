# frozen_string_literal: true

# Shows portable values, snapshots, history, byte streams, compaction, and incremental replication.
# Temporary files are removed after the example.

require "xitdb"
require "json"
require "tmpdir"
require "stringio"

Dir.mktmpdir("xitdb-portable-") do |directory|
  XitDB.open(File.join(directory, "source.xit"), hash: :sha256) do |db|
    db.transaction do |root|
      root["profile"] = { "name" => "Ada", "visits" => 0 }
      root["tags"] = Set["ruby", "storage"]
      root["events"] = XitDB.linked_array
      root["events"].push("created", "visited")
      root["counted"] = XitDB.map(counted: true)
      root["counted"]["n"] = XitDB.uint((2**64) - 1)
      root["opaque"] = XitDB.bytes("payload", format_tag: "zz")
      root.write_bytes("attachment") do |io|
        io.write("abc")
        io.write("def")
      end
    end
    before = db.snapshot
    db.transaction { |root| root["profile"]["visits"] += 1 }
    raise "snapshot changed" unless before.dig("profile", "visits").zero?
    raise "revision changed" unless db.snapshot(revision: before.revision).dig("profile", "visits").zero?
    raise "stream differs" unless db.snapshot.open_bytes("attachment", &:read) == "abcdef"
    raise "linked slice differs" unless db.snapshot["events"].split(1).last.to_ruby == ["visited"]
    raise "history missing" unless db.history.fetch(0).dig("profile", "visits").zero?

    db.revert(before)
    raise "revert differs" unless db.snapshot.dig("profile", "visits").zero?

    db.compact(to: File.join(directory, "compact.xit")).close
    XitDB.open(File.join(directory, "compact.xit"), readonly: true) do |compact|
      raise "compaction differs" unless compact.snapshot.dig("profile", "name") == "Ada"
    end

    # Bootstrap a separate replica, then send one incremental update.
    full = StringIO.new("".b)
    finish = db.core.replica_state.committed_size
    db.core.read_committed(0, finish, full)
    full.rewind
    replica = XitDB::Core::Database.copy_replica(to: File.join(directory, "replica.xit"), source_io: full,
                                                 length: finish)
    begin
      db.transaction { |root| root["profile"]["visits"] = 2 }
      start = db.core.replication_start(replica.replica_state)
      raise "full staging required" if start.zero?

      finish = db.core.replica_state.committed_size
      delta = StringIO.new("".b)
      db.core.read_committed(start, finish, delta)
      delta.rewind
      replica.apply_replicated(start, delta, finish - start)
      raise "replica differs" unless replica.replica_state == db.core.replica_state
    ensure
      replica.close
    end
    puts JSON.generate(name: db.snapshot.dig("profile", "name"), visits: db.snapshot.dig("profile", "visits"))
  end
end
