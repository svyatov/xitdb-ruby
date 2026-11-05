# Portable profile

`require "xitdb"` provides `XitDB.open(path, readonly: false, hash: nil, lock_timeout: 5.0)` and `XitDB.memory(hash: :sha1)`.
New files use SHA-1 with identifier `sha1`. Use `hash: :sha256` to create SHA-256 files with identifier `sha2`.
Hash collections inherit upstream collision semantics. Bulk input and merge reject distinct keys that collapse to one byte key with `KeyCollisionError`.
Recognized file hashing is selected on open. Unknown or absent hash identifiers require explicit compatible configuration.

## Transactions and lifetime

A transaction block receives a writable root map. Normal completion publishes its mutations and returns a committed `Snapshot`.
The block runs once after the writer lock succeeds. Exceptions, `break`, `throw`, and non-local `return` abort publication.
`next` completes normally. Its return value does not replace the root.
A transaction without mutations reuses the previous snapshot. Reassigning an equal value can append history.

Nested writes to the same file raise `TransactionStateError`. Each assignment is atomic even if its error is rescued inside the transaction.
Coercion and codec callbacks may read transaction views. They cannot start another logical mutation while one is applying, including through another Context.
Byte-stream callbacks run outside finalization and permit non-overlapping sibling writes.

`db.snapshot` captures committed data, including inside a transaction. Transaction views expose the uncommitted data.
Snapshot views remain valid until handle close. Transaction views expire when their block ends and belong to their thread.
Replacing or deleting an ancestor expires earlier child views. Errors are `ClosedError`, `ExpiredViewError`, or `ReadOnlyError` as applicable.

Assignment captures input immediately. Assigning a view from the same transaction captures its value without later aliasing.
Foreign views require explicit copying or `to_ruby`; direct assignment raises `ForeignValueError`.
Read Strings are frozen. `to_ruby` creates independent mutable containers and Strings.
Cyclic inputs or materialization of cyclic graphs raise `CyclicValueError` with the offending path.

## Values

| Input | Representation |
| --- | --- |
| `nil` | Occupied null slot, distinguishable from absence with `key?` |
| Integer from `-2**63` through `2**64 - 1` | Exact signed or unsigned upstream integer |
| `XitDB.uint(n)` | Explicit unsigned slot |
| Float | IEEE 64-bit float |
| String | Untagged bytes |
| Hash, Array, Set | Ordinary upstream map, array list, or set |
| `XitDB.bytes(data, format_tag: "zz")` | Opaque tagged bytes |

Map keys and set members must be Strings. Boolean, Symbol, temporal, and arbitrary object values require the Ruby profile or an explicit application encoding.
Strings preserve bytes. Reads use UTF-8 for valid UTF-8 bytes and ASCII-8BIT otherwise; original encoding metadata is not retained.
Hash defaults, default procs, and unsupported input behavior raise `UnsupportedValueError`.

## Collections and costs

Declarations include `XitDB.map(counted:)`, `XitDB.set(counted:)`, `XitDB.array`, `XitDB.linked_array`, `XitDB.sorted_map`, and `XitDB.sorted_set`.
Assign a declaration, then mutate its returned view. Native Hash, Array, and Set select ordinary representations.
Views include `Enumerable`; they do not subclass native collections.

| View | Reads | Writes inside a transaction |
| --- | --- | --- |
| Map | `[]`, `fetch`, `dig`, `key?`, `each`, `each_key`, `each_value`, `keys`, `values` | `[]=`, `delete`, `clear`, `merge!` |
| Array | `[]`, `fetch`, `first`, `last`, `length`, `each` | `[]=`, `<<`, `push`, `pop`, `insert`, `delete_at`, `concat`, `clear` |
| Set | `include?`, `each` | `add`, `delete`, `clear` |
| Sorted map/set | Corresponding reads, `rank`, `from`, `from_index`, `page` | Corresponding writes |
| Linked array | Array reads, slices, `split(index)` | Array writes and concatenation |

All views support `size`, `empty?`, `to_ruby`, and bounded `inspect`. Missing map keys return nil; `fetch` raises `KeyError`.
Array positions support negative indexes. Assignment beyond the end fills the gap with stored nil.
Reads never create missing parents. Unimplemented operations raise ordinary `NoMethodError`.
Plain hash map/set size requires traversal. Counted maps/sets, arrays, and sorted collections have constant-time size.
Equality can traverse the subtree. Scalar reads allocate that scalar; `keys`, `values`, and eager enumeration allocate their results.

Enumeration is incremental; `each` without a block returns an enumerator. Snapshot enumeration stays read-only and stable.
Transaction enumeration permits replacing values and editing descendants. Changing membership or order invalidates its iterator with `ConcurrentModificationError`.

Sorted collections compare raw bytes lexicographically. `from(key)` is inclusive; `from_index(index)` seeks by rank.
`page(offset:, limit:)` returns an incremental enumerator and seeks without scanning skipped entries.
Keep one snapshot for stable pagination. Applications maintain secondary indexes in the same transaction as their records.
See [indexed users](../examples/indexed_users.rb).

## History and streams

`db.history[index]` returns a snapshot or nil. Negative indexes count backward; `fetch` raises `IndexError` for a missing index.
Enumeration is incremental. A file without history has a virtual empty map and no revision.
`snapshot.revision` is opaque and immutable. `db.snapshot(revision: token)` validates its ancestor proof and reopens that history entry.
Tokens survive ordinary appends but identify a file generation, not a globally canonical value hash.
`db.revert(snapshot_or_revision)` appends the selected root and retains subsequent history. Foreign tokens raise `ForeignRevisionError`.

`view.write_bytes(key) { |io| io.write(chunk) }` streams an untagged value. A callback failure discards that assignment.
`view.open_bytes(key) { |io| ... }` yields a bounded reader with `read`, `readpartial`, `seek`, `rewind`, `pos`, `size`, and `eof?`.
Use these block-scoped IO objects inside their blocks. Reads do not exceed the selected value.
Byte transfers use 64 KiB chunks; writes buffer at most 2 MiB. Ordinary String lookup still allocates the complete String.
Pass a length to `read` for bounded application buffers; `read` without a length allocates the entire remaining byte value.

## Maintenance and compatibility

`db.compact(to: path)` returns an open writable handle to a separate file with one latest root, preserving profile and hashing.
The caller owns and closes the returned handle.
The destination must be missing or zero bytes; an initialized empty database is nonempty and rejected.
Source snapshots remain valid. Application code controls file replacement and reader reopening.
See [conversion and replication](core.md) for separate-destination ownership and failure contracts.

The pinned Go, TypeScript, Java, and Zig references have reciprocal storage and maintenance checks.
TypeScript's Number convenience reader loses precision outside the exact Number integer range.
Its signed `Slot.fromBytes` carrier also makes `readUint` reject values above `2**63 - 1` with `ExpectedUnsignedLongException`.
Java's convenience `Database.Uint` writer rejects negative long carriers, and `readUint` rejects those stored carriers.
Java's public raw Slot writer preserves these unsigned bits. TypeScript can also write and retain the full unsigned bits.
Raw-bit, compaction, and replication checks pass separately from these convenience API limits. Ruby retains the full upstream integer range.
