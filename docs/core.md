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

## Verify a staged restore

Keep the staged file under exclusive application control until installation. Verification opens it read-only and captures the latest committed boundary on that descriptor. Appends after capture fall outside the scan. Replacing the pathname after open leaves the scan on the original descriptor. External modification of already committed bytes during the scan is unsupported.

```ruby
require "xitdb"

staged = "restore/staging.xit"
result = XitDB.verify!(staged) # raises on failure
puts "Verified #{result.profile} snapshot through byte #{result.committed_size - 1}"
puts "Required application codecs: #{result.codec_ids.join(", ")}"
# Apply application-specific restore checks before installing the staged file.
```

Core versions 1 and 2 support portable `sha1` (20 bytes), portable `sha2` (32, 48 or 64 bytes), and Ruby `rb05` (32 bytes). The returned `XitDB::VerificationResult` and its fields are immutable. `profile` is `:portable` or `:ruby`, `hash_id` is the four-byte header identifier, and `hash_size` is the digest width in bytes. `committed_size` is the exclusive end of the captured commit. `codec_ids` lists the distinct Ruby application codec IDs encountered, including unknown IDs. Verification requires no codec registry and never calls application loaders.

The verifier checks the root trailer checksum, the path through history to the latest root, and every value reachable from that root. Checks include record extents and tags, visible array entries, collection counts, key hashes and routing, tree ordering, and subtree sizes. Ruby checks also cover record metadata and arity, field dictionaries, lookup and ordered storage agreement, builtin scalar fields, and every row and cell of sequential, offset-directory, fixed-stride and padded pages, including checksums where defined.

A valid initialized file with no history succeeds. A zero-byte file fails. Earlier snapshots, unreachable records and unpublished tail bytes are outside the scan. Portable tagged data and Ruby application codec payloads are opaque. Ordinary byte records have no general payload checksum. Success establishes structural readability of the captured snapshot. Application rules and payload authenticity require separate checks.

The first structural defect raises `XitDB::VerificationError`, a subclass of `XitDB::CorruptionError`. Its `check` identifies the failed check. Its `offset` is the absolute byte offset when known and its `path` identifies the logical location when available. A page checksum error refers to the start of the page contents. Unsupported formats raise `XitDB::UnsupportedVerificationFormatError`. Filesystem errors propagate, including `Errno::ENOENT` for a missing source.

The verifier reads at most 64 KiB per read. These fixed budgets apply even to structurally valid files:

| Resource | Limit |
| --- | ---: |
| Active referenced records (`depth`) | 256 |
| Retained reference contexts per traversal (`references`) | 262,144 |
| Diagnostic path length | 1,024 bytes, with a trailing `[...]` on truncation |
| Retained diagnostic paths (`path_bytes`) | 1 MiB |
| Scalar and page decoding work (`scalar_bytes`) | 8 MiB |
| Codec inventory (`codec_bytes`) | 1 MiB, charged as identifier bytes plus 96 bytes per distinct ID |
| Completed record summaries (`summary_bytes`) | 16 MiB, charged as 64 bytes per summary |
| Comparison buffers (`comparison_bytes`) | 16 MiB |

Decoding charges include space for intermediate values. Large opaque values stream in chunks. Exhausting a budget raises `XitDB::VerificationLimitError`; its `limit` names the resource. The snapshot remains unverified.

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
Each writable pathname handle synchronizes its containing directory after its first file synchronization, including handles opened on existing files.
This lets cooperating initializers and writers establish pathname durability independently. Later commits on that handle synchronize only the file.
Opening an existing file validates its contents; it does not confirm durability of bytes left by an earlier failed publication.
Creation rejects dangling final symlinks with `Errno::ENOENT`; open the intended target path directly. Symlinks to existing files remain supported.
Memory handles provide atomic visibility without disk durability.
`CommitError#outcome` is `:not_committed` before publication, `:unknown` during uncertain publication, or `:committed` after confirmed synchronization.
Uncertain publication, failed rollback, or lock-release failure requires reopening before further writes. Callbacks are never automatically retried.
Library errors inherit `XitDB::Error`; standard argument, missing-key, index, and range failures retain Ruby error classes.

## Physical contract

The immutable database header occupies 20 bytes.
In version 2, four padding bytes precede the eight-byte committed size at offset 24.
A commit requests an aligned eight-byte write. A short write can still expose a partial size before the retry.
In version 1, the root header contains a nine-byte cached slot and the eight-byte committed size at offset 29.
A version 1 file can still have a torn header read during a concurrent commit. The trailer supplies the root in both versions.
A trailer contains a root slot, commit identifier, and CRC-64/XZ checksum, occupying 25 bytes.
An initialized empty database occupies 57 bytes in version 2 or 62 bytes in version 1.
Parsing checks object ranges against committed boundaries before allocating.
Use `db.header.committed_size_offset` and `db.header.data_offset` for version-specific offsets.
Graph traversal uses an explicit stack. Write buffers are bounded at 2 MiB, byte transfers at 64 KiB, and offset caches spill after 16,384 entries.

`XitDB::Core::Bytes` owns physical byte storage, including inline selection, lengths, format tags, and bounded transfers.
Scalar materialization, streams, conversion, and compaction use that implementation. Profiles retain payload interpretation and encoding rules.
Compaction preserves external byte records, including short payloads and unknown format tags.

The private `:record` extension uses tag code 17, after the upstream tags.
A record contains unsigned 32-bit metadata, an unsigned 32-bit field count, and consecutive nine-byte slots, all in big-endian order.
The field count cannot exceed 32. Readers check the count and captured boundary before loading fields.
Compaction reserves each record before remapping its fields, preserving sharing and cycles.
The enclosing logical mutation owns rollback and publication. Record construction appends complete bytes without publishing a root.
Portable writers do not emit this extension. Upstream implementations require extension support before maintaining graphs that contain it.

The port preserves the package's [MIT license notice](../LICENSE).
Reference revisions and source hashes are recorded in `test/interop/manifest.json` in the source checkout.
