# Storage core and maintenance

`require "xitdb/core"` exposes raw upstream storage. Public profile handles also expose `db.core`.
Core accepts arbitrary valid root layouts; public profiles require a history array containing logical root maps.
Unknown format tags remain uninterpreted bytes. Raw graphs can contain sharing and cycles that public materialization rejects.

## Raw collections

```ruby
require "xitdb/core"

db = XitDB::Core::Database.memory
begin
  db.transaction do |root|
    list = XitDB::Core::ArrayList.new(root)
    list.append(XitDB::Core::Slot.uint(42))
  end
  list = XitDB::Core::ArrayList.new(db.root_cursor)
  p list.cursor_at(0).slot.value # 42
ensure
  db.close
end
```

Core constructors include `ArrayList`, `LinkedArrayList`, `HashMap`, and `SortedMap`.
`HashMap` supports counted and set variants; `SortedMap` supports set mode.
Callers provide raw digest bytes to hash collections and raw key bytes to sorted collections.
Slots contain a tag, full flag, and unsigned 64-bit payload. Use `db.bytes(data, format_tag:)` during a transaction for byte slots.
Core cursor ownership and transaction-local references are lower-level contracts; public views provide value capture and operation rollback.
Core empty stores may initialize. Public opening rejects pre-existing zero-byte files.

## Conversion and copying

`db.convert(to:, profile:, history: :all, transform: nil)` returns an open writable destination handle owned by the caller.
Always close that handle. Destinations must be missing or zero bytes, including for empty sources.
`history:` accepts only `:all` and `:latest`. Empty sources retain zero history entries.
Same-profile symbols retain source configuration; cross-profile symbols select defaults.
Exact configured `XitDB::Profiles::Portable` and `XitDB::Profiles::Ruby` instances create fresh target profiles and registries.

```ruby
require "xitdb/ruby"

XitDB::Ruby.memory do |db|
  db.transaction { |root| root[:enabled] = true }
  portable = db.convert(to: "converted.xit", profile: :portable, history: :latest,
    transform: ->(value:, path:, role:) { role == :key ? value.to_s : (value == true ? 1 : value) })
  begin
    p portable.snapshot["enabled"] # 1
  ensure
    portable.close
  end
end
```

Transforms run once for each source scalar or logical key. Keywords are `value:`, `path:`, and `role:` (`:key` or `:value`).
Paths are immutable and relative to the copied source root. Returned products are encoded without recursively applying the transform.
Ruby-only keys, booleans, native numeric sorted keys, and unknown custom codecs need explicit portable representations.
Collapsing distinct keys raises `KeyCollisionError`. Opaque portable `rb` payloads also require an explicit transform for Ruby targets.
Sorted kinds remain sorted. Portable-to-Ruby sorted keys use the String kind.

Inside a destination transaction, use `root.context.copy_from(source_view, at: ["parent", "copy"], transform: nil)`.
It returns the installed destination view. `at:` requires a full Array path with existing parents.
`at: []` explicitly replaces the root with a Map or sorted Map. Previous child views expire; the transaction root remains usable.
No view-level copy wrapper exists. Direct foreign-view assignment remains an error.

Conversion traverses roots and histories incrementally. Transform-free Strings and opaque bytes stream in 64 KiB chunks.
A transform may allocate its complete scalar input. Shared data is copied independently across histories.
The [measurements](benchmarks.md) record 25-history shallow conversions expanding to 32.36 and 9.35 times source size.
Depth-600 repeated-history diagnostics exceeded ten seconds and were interrupted; those are not completed conversion timings.
Compaction retains only the latest root and can preserve physical sharing. It is separate from logical conversion.

## Replication

Run [the portable example](../examples/portable.rb) for a complete bootstrap and incremental update.
Use binary caller-owned IO. Transport objects stay open and input consumes only the declared length.

1. Capture `finish = source.replica_state.committed_size` from a Core handle.
2. Export `source.read_committed(0, finish, io)`, then rewind the transport.
3. Bootstrap with `Core::Database.copy_replica(to: missing_path, source_io: io, length: finish)`.
4. Negotiate updates with `start = source.replication_start(replica.replica_state)`.
5. For positive start, export through a captured finish and call `replica.apply_replicated(start, io, finish - start)`.

`ReplicaState` is immutable with `committed_size` and `checksum`. `replication_start` returns the matched size or zero.
`read_committed` and `apply_replicated` return nil. `copy_replica` returns a separate validated open writable Core handle; its caller closes it.
A zero negotiation requires a full copy to another missing or zero-byte path. `apply_replicated(0, ...)` raises `ArgumentError`.
Application code controls replacement and reader reopening. No API renames a staged file over a live replica.
Replication preserves bytes and profile metadata. It does not convert profiles or merge independent writers.

Known incremental aborts restore the previous size. Known staging aborts attempt to restore zero, subject to storage cleanup success.
Staging synchronization failure raises `CommitError` with outcome `:unknown` and retains on-disk output, which may be partial.
Do not assume that an uncertain staged image is complete or valid. Transport failures preserve their original exception identity.
Short input raises `EOFError`; invalid trailers raise `CorruptionError`.

## Locking and durability

Writers serialize across cooperating processes and threads. The writer refreshes committed state after acquiring its lock.
`lock_timeout:` defaults to five seconds. `BusyError` occurs before the transaction callback runs.
Snapshot reads use positional access and do not acquire the exclusive writer lock.
Closing waits for active operations; closing inside that handle's transaction raises `TransactionStateError`.

File publication synchronizes data before publishing and synchronizing the root header. A successful transaction returns after confirmed synchronization.
Memory handles provide atomic visibility without disk durability.
`CommitError#outcome` is `:not_committed` before publication, `:unknown` during uncertain publication, or `:committed` after confirmed synchronization.
Uncertain publication, failed rollback, or lock-release failure requires reopening before further writes. Callbacks are never automatically retried.
Library errors inherit `XitDB::Error`; standard argument, missing-key, index, and range failures retain Ruby error classes.

## Physical contract

The header occupies 20 bytes. The root header adds a nine-byte slot and eight-byte committed size.
A trailer contains a root slot, commit identifier, and CRC-64/XZ checksum, occupying 25 bytes.
An initialized empty database occupies 62 bytes. Parsing checks object ranges against committed boundaries before allocating.
Graph traversal uses an explicit stack. Write buffers are bounded at 2 MiB, byte transfers at 64 KiB, and offset caches spill after 16,384 entries.

The port preserves the package's [MIT license notice](../LICENSE).
Reference revisions and source hashes are recorded in `test/interop/manifest.json` in the source checkout.
