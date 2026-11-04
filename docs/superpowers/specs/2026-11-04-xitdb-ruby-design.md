# xitdb for Ruby: compatible storage and Ruby value profiles

Status: approved by the user on 2026-11-04.

## Intent

Build a pure Ruby implementation of xitdb with an interface suited to Ruby developers. The first release includes a compatible storage core, a portable interface, and an optional Ruby extension.

The user selected transactional collection views, called O1 in the design discussion. The user requires cross-language access without custom decoders through the portable interface. The user also requires the Ruby extension in the first release.

No personal application or framework integration drives this design. Evaluate the interface through examples covering nested data, atomic index updates, history, ordered pagination, streaming, and Ruby value round trips.

## Goals and limits

- G1: Implement every upstream storage type and collection without changing the upstream binary format.
- G2: Read and write portable files through the reference implementations without a Ruby codec.
- G3: Provide explicit transactions, stable snapshots, lazy nested collections, and actionable errors.
- G4: Preserve documented Ruby value semantics through an explicit Ruby profile.
- G5: Keep file allocation, hashing, transactions, compaction, and replication in one storage implementation.

The first release targets MRI Ruby 3.3 and later. It uses Ruby's standard libraries and shipped gems. The gem requires no compiler or additional runtime service.

SQL, an ORM, Rails integration, automatic secondary indexes, a network server, and a general plugin framework are outside this release. Benchmarks establish measured behavior; the project makes no unmeasured performance claim.

Arbitrary Ruby object persistence is outside the value contract. Executable objects, identity-based containers, singleton behavior, and cyclic Ruby inputs require an explicit unsupported-value error.

## Approaches

| Approach | Benefit | Cost | Decision |
| --- | --- | --- | --- |
| O1: Transactional collection views | Familiar collection operations with explicit persistence | Requires precise ownership and lifetime rules | Selected by the user |
| O2: Functional persistent collections | Each edit produces an immutable replacement value | Adds unfamiliar operations for ordinary Ruby updates | Not selected |
| O3: Explicit storage locations | Direct control over paths, types, and streaming | Adds ceremony to ordinary collection access | Retained only as lower-level core access |

O1 applies to both public profiles. The Ruby extension changes value representation, key semantics, and ordered collection behavior. It does not create a second storage engine.

## Layers and ownership

### L1: Compatible storage core

`XitDB::Core` owns binary encoding, headers, slots, cursors, hashing configuration, storage allocation, and commit publication. It also owns compaction and replication.

The core exposes hash maps, hash sets, and their counted variants. It also exposes array lists, linked array lists, sorted maps, and sorted sets.

The core accepts raw hash bytes and tagged byte values. It preserves unknown format tags without interpreting them. Its lower-level interface supports every valid upstream root layout.

Memory and file storage share this implementation. Buffering is an internal file optimization. It is not a separate public database type.

### L2: Portable Ruby interface

`require "xitdb"` exposes `XitDB.open` and `XitDB.memory`. These entry points use the portable profile.

The profile follows upstream byte-key hashing and collection layouts. It introduces no Ruby-specific tags or implicit object serialization.

### L3: Ruby extension

`require "xitdb/ruby"` exposes `XitDB::Ruby.open` and `XitDB::Ruby.memory`.

The Ruby profile adds typed keys, encoded Ruby values, and insertion-ordered maps and sets. Its public transaction and snapshot operations match L2.

Configuration belongs to each database handle. Requiring the extension does not alter L2 behavior or install global monkey patches.

## Opening files and profiles

```ruby
require "xitdb"

XitDB.open("shared.xit") do |db|
  db.transaction do |root|
    root["profile"] = { "name" => "Ada", "visits" => 0 }
  end

  before = db.snapshot

  db.transaction do |root|
    root["profile"]["visits"] += 1
  end

  before.dig("profile", "visits")       # => 0
  db.snapshot.dig("profile", "visits")  # => 1
end
```

`open` creates a missing file. `readonly: true` requires a valid file and disables every write operation. Opening an invalid file leaves its bytes unchanged.

The block form closes the handle when the block exits. The non-block form returns a handle with `close` and `closed?`.

L2 and L3 use the conventional top-level history array. Each history entry contains one logical root map. The core remains available for other root layouts.

An initialized file with no history entries has a virtual empty root map. Its snapshot has no revision. The first changed transaction creates the first history entry.

L2 validates the file format, hash identifier, hash size, and root layout. It accepts recognized upstream hashing conventions. A missing or unknown hash identifier requires an explicit hash configuration.

New portable files default to SHA-1 with header identifier `sha1`. This matches the widest reference-wrapper support. Creation also supports SHA-256 with identifier `sha2`.

Hash-based collections inherit upstream hash-collision semantics. Documentation describes the hash choice and the option to create SHA-256 files.

The Ruby profile uses header identifier `rb01`. This identifies SHA-256 over versioned canonical Ruby key bytes. The identifier also selects the Ruby profile's collection layout.

L2 rejects a Ruby-profile file with `ProfileMismatchError`. L3 rejects a portable file with the same error. The error names the appropriate entry point or explicit conversion operation.

The core can inspect either profile as ordinary upstream structures. Other languages require the Ruby profile specification to interpret its logical values and keys.

Opening never upgrades a file or changes its profile. File conversion writes a separate destination.

## Transactions and snapshots

`db.transaction` acquires the writer before invoking its block. The block receives a mutable root map view. It runs once against the latest committed state.

Normal completion publishes every change atomically. An exception, `break`, `throw`, or non-local `return` aborts publication. The original exception propagates unchanged.

`next` completes the block normally. Its value does not become the database root. Explicit mutation methods define the resulting root.

The method returns the committed `Snapshot`. A block containing no mutations returns the previous snapshot without appending history. Reassigning an equal value may create a revision.

Nested write transactions for the same file raise `TransactionStateError`. The first release provides no savepoints or manual commit method.

Each mutation operation is atomic within the transaction. A rescued assignment error leaves the transaction's logical state unchanged by that assignment.

`db.snapshot` captures one committed version. Every access through that snapshot reads the same version, including accesses made during later transactions.

Snapshots and nested snapshot views remain valid until their database handle closes. Reading through a closed handle raises `ClosedError`.

Transaction views belong to their transaction and thread. Using one after block exit raises `ExpiredViewError`. Replacing or deleting an ancestor invalidates its previously obtained child views.

`db.snapshot` inside a write block returns committed data. The block's root view supplies uncommitted data.

`db.history[index]` returns a snapshot, with negative indexes counting from the end. Missing indexes return `nil`; `fetch` raises `IndexError`. History enumeration is incremental.

`Snapshot#revision` returns an opaque, immutable revision token. `db.snapshot(revision:)` reopens that revision. Tokens identify a file generation and history entry, not a timestamp.

`db.revert(snapshot_or_revision)` appends a revision containing the selected root. It retains subsequent history. Cross-file revisions raise `ForeignRevisionError`.

## Value ownership

Assignment captures the supplied value immediately. Later mutations of a supplied Ruby object cannot change stored data.

Assigning a database view captures its value at assignment. Subsequent writes to either location cannot mutate the other through shared storage.

The implementation may share immutable storage internally. It must hide upstream transaction-local aliasing and cursor freeze operations from L2 and L3 callers.

Views from another database require an explicit copy operation or materialization. Direct assignment raises `ForeignValueError` before changing transaction state.

Strings returned through views are frozen. Modifying a string uses replacement, such as `root["name"] += " Smith"`.

`to_ruby` recursively produces independent, mutable Ruby containers and strings. It does not preserve storage identity or shared object identity.

Inputs with cycles raise `CyclicValueError` with the first offending path. Materializing a cyclic upstream graph raises the same error. The core still supports valid upstream references and cycles.

## Portable values and keys

| Ruby input | Stored representation | Read behavior |
| --- | --- | --- |
| `nil` | Occupied upstream `none` slot | `nil`, distinct from an absent entry |
| `Integer` within signed 64-bit range | Upstream signed integer | Ruby `Integer` |
| Larger nonnegative `Integer` within unsigned 64-bit range | Upstream unsigned integer | Ruby `Integer` |
| `Float` | Upstream 64-bit float | Ruby `Float` |
| `String` | Untagged upstream bytes | Frozen `String` |
| `Hash` with string keys | Upstream hash map | Lazy map view |
| `Array` | Upstream array list | Lazy array view |
| `Set` with string members | Upstream hash set | Lazy set view |
| Explicit collection declaration | Selected upstream collection | Corresponding lazy view |
| Explicit tagged bytes | Upstream bytes and unchanged tag | Opaque tagged-byte value |

Portable string writes preserve bytes. Reads use UTF-8 when the bytes form valid UTF-8; otherwise, they use ASCII-8BIT. The portable profile does not preserve original Ruby encoding metadata.

Portable map keys and set members must be strings. Symbols, booleans, temporal objects, larger integers, and unregistered objects raise an error. No symbol shorthand is included in L2.

Portable hashes have no insertion-order guarantee. A native Ruby Hash input with a default value or default proc raises `UnsupportedValueError`.

The optional `XitDB.uint(value)` declaration permits an explicitly unsigned storage kind. Ordinary Ruby integer reads retain the exact value of either upstream integer kind.

The TypeScript reference convenience reader converts integers to `Number`. Its exact integer range limits cross-language round trips through that reader. Ruby retains the full upstream integer range.

## Ruby values and keys

```ruby
require "xitdb/ruby"

XitDB::Ruby.open("app.xit") do |db|
  db.transaction do |root|
    root[:enabled] = true
    root[:created_at] = Time.utc(2026, 11, 4, 12)
    root[:large_number] = 2**200
    root[:profile] = { name: "Ada", "name" => "Different key" }
  end

  db.snapshot[:profile].keys # => [:name, "name"]
end
```

L3 supports `nil`, booleans, arbitrary-size integers, floats, strings, symbols, arrays, hashes, and sets. It also supports `Time`, `Date`, `DateTime`, `BigDecimal`, and `Rational` values.

Strings preserve bytes and encoding. Symbols remain distinct from strings. Integer and float keys remain distinct. Float keys normalize signed zero and reject `NaN`.

Ordinary Ruby map keys and set members use these scalar classes: `NilClass`, `TrueClass`, `FalseClass`, `Integer`, `Float`, `String`, and `Symbol`.

Collection keys, custom object keys, and temporal keys are outside this hash-key contract. Their rejection is explicit. Sorted collections have separate key kinds defined below.

Canonical key bytes implement Ruby equality for the supported key classes. They never use Ruby's process-dependent `Object#hash` as persistent data.

ASCII-compatible string keys with equal ASCII bytes compare as equal. Non-ASCII string keys preserve Ruby's encoding-sensitive equality. Golden fixtures cover these rules.

Ruby maps preserve insertion order. Updating a key retains its position. Deleting and reinserting a key moves it to the end. Ruby sets preserve insertion order.

Container subclasses require a registered codec. Hash defaults, default procs, identity comparison, and cyclic inputs raise `UnsupportedValueError` or `CyclicValueError`.

`Time` preserves its exact instant, UTC offset, and UTC flag. Named time-zone rules are not persisted. `Date` and `DateTime` preserve their calendar start and numeric date or instant.

`BigDecimal` preserves numeric value and signed zero. `Rational` preserves its exact numerator and denominator. Floats preserve IEEE values, including infinities and `NaN` values outside keys.

The profile records a Ruby encoding name. An unavailable encoding raises `UnsupportedEncodingError` when that value is decoded.

## Ruby representation and codec seam

The Ruby profile uses upstream primitives and containers exclusively. It does not add storage tags to the upstream tag enum.

Encoded scalar values use the upstream byte format tag `rb`. Their payload contains an encoding version, a type identifier, and deterministic type data.

Ruby containers use versioned envelopes built from upstream collections. Each envelope identifies its logical container type. Native arrays remain incrementally addressable.

An ordered Ruby map maintains a key lookup index and a sorted insertion-order index. Both indexes change within the same core transaction.

The order index uses monotonic insertion identifiers. Deletion removes its index entry. It does not require shifting every later element or retaining tombstones indefinitely.

Ruby sets use the same ordering contract. Every collection maintains a count without scanning all members.

Canonical key encoding, scalar encoding, and container envelopes belong to the Ruby profile. L1 owns their physical storage and transaction publication.

The implementation plan must specify the exact version-one bytes and envelopes before writing the Ruby profile implementation. Golden fixtures make this specification a release contract.

Custom codecs are configured per handle:

```ruby
money_codec = XitDB::Ruby::Codec.new(
  id: "example/money/v1",
  type: Money,
  dump: ->(money) { money.to_storage_bytes },
  load: ->(bytes) { Money.from_storage_bytes(bytes) }
)

XitDB::Ruby.open("shop.xit", codecs: [money_codec]) do |db|
  db.transaction { |root| root[:price] = Money.new(100, "USD") }
end
```

Codec dumps return byte strings. Codec identifiers are stable, explicit strings that include their schema version. Duplicate identifiers, overlapping registrations, and builtin overrides raise `CodecConfigurationError`.

Registered codecs support values only. Codec callbacks do not bypass transaction or ownership rules. Callback failures abort the affected assignment.

Unknown custom codecs produce an immutable opaque encoded value. The core preserves its bytes. Reading a file never loads arbitrary classes or executes `Marshal.load`.

## Collection interface and costs

Views use distinct classes. They do not subclass Ruby Hash, Array, or Set. All collection views support `Enumerable`, `empty?`, `size`, `to_ruby`, and bounded `inspect`.

| Collection | Reads | Mutations inside a transaction |
| --- | --- | --- |
| Map | `[]`, `fetch`, `dig`, `key?`, `each`, `each_key`, `each_value`, `keys`, `values` | `[]=`, `delete`, `clear`, `merge!` |
| Array | `[]`, `fetch`, `each`, `first`, `last`, `length` | `[]=`, `<<`, `push`, `pop`, `insert`, `delete_at`, `concat`, `clear` |
| Set | `include?`, `each` | `add`, `delete`, `clear` |
| Sorted map or set | Ordinary reads plus `rank`, `from`, `from_index`, `page` | Ordinary corresponding mutations |
| Linked array | Array reads and incremental slice access | Array mutations plus efficient split and concatenation |

Absent map entries return `nil`; `fetch` raises `KeyError`. Stored `nil` remains distinguishable with `key?`.

Arrays follow Ruby's negative-index and missing-index rules for supported methods. Assigning beyond the end fills intervening entries with stored `nil`.

Snapshot mutation raises `ReadOnlyError`. Reads never create missing parent collections. Unimplemented methods retain ordinary Ruby `NoMethodError` behavior.

`each` without a block returns an enumerator. Traversal reads entries incrementally. `Enumerable#lazy` provides Ruby's normal lazy transformations.

`keys`, `values`, and eager Enumerable methods allocate their ordinary Ruby result containers. Nested stored collections remain views unless `to_ruby` is called.

Loading a scalar string allocates that string. Streaming byte methods provide incremental access for larger values. No size-dependent implicit switch changes a scalar's return type.

`size` is constant-time for counted maps, arrays, sorted collections, and Ruby-profile collections. Plain portable hash maps and sets require traversal.

Collection equality compares logical values and can traverse the selected subtree. `inspect` reports type, profile, and location without traversing the collection.

Snapshot iterators yield read-only values from their captured snapshot. Transaction iterators yield live values, including writable child collection views.

Replacing existing values and editing descendants during transaction iteration are permitted. Changing the iterated collection's membership or order invalidates its iterator.

An invalidated iterator raises `ConcurrentModificationError` before yielding another element. Replacing an ancestor expires its iterators and child views.

Portable declarations include `XitDB.map(counted:)`, `XitDB.set(counted:)`, `XitDB.array`, `XitDB.linked_array`, `XitDB.sorted_map`, and `XitDB.sorted_set`.

Declarations are immutable inputs to assignment. Reading the resulting location returns a usable view. Native Hash, Array, and Set inputs select their profile's ordinary collection representation.

## Ordered access and byte streams

Portable sorted collections compare raw key bytes lexicographically. The portable interface does not apply locale collation or numeric coercion.

Ruby sorted collections require an explicit key kind: `:string`, `:integer`, `:float`, or `:time`. Each kind has a versioned, order-preserving encoding.

Ruby sorted strings use UTF-8 byte order. Integer order includes arbitrary-size integers. Float keys reject `NaN`; time keys order by exact instant.

`from(key)` begins inclusively at the first matching or greater key. `from_index(index)` seeks directly to a rank. `page(offset:, limit:)` returns an incremental enumerator.

These operations use the upstream tree rather than scanning skipped entries. Pagination belongs to a snapshot, so later commits do not change its results.

Applications maintain their own indexes. A record and its indexes can change through the same transaction root.

`view.write_bytes(key) { |io| ... }` writes an untagged byte value incrementally. Normal completion finalizes it; block failure discards that assignment.

`view.open_bytes(key) { |io| ... }` provides a bounded reader for untagged bytes. Readers support standard Ruby read, seek, and position operations.

Stream handles expire at block exit. Streams do not support overlapping mutations of the same value. `IO.copy_stream` integration is covered by running examples.

## Maintenance, copying, and conversion

`db.compact(to:)` writes a separate file containing the latest logical root and the reachable storage. It preserves the profile and compatible hash configuration.

The destination must be missing or empty. Compaction never replaces the source file. Source snapshots remain valid through their original handle.

`db.convert(to:, profile:, history: :all, transform: nil)` writes a separate file. It preserves all history by default; `history: :latest` selects only the latest root.

Portable-to-Ruby conversion preserves portable values and creates Ruby collection envelopes. An unordered source map gains the source traversal order, without a prior ordering guarantee.

Ruby-to-portable conversion preserves representable values. Unsupported keys and values require the explicit transform callback. Key collisions after conversion raise an error.

Choosing the portable target accepts its documented ordering and string-encoding contract. Conversion never invents encodings for booleans or Ruby-specific objects.

Conversion traverses incrementally. It does not materialize complete histories or roots as native Ruby objects. Codec callbacks apply only to individual encoded values.

Cross-file copying uses the same conversion machinery. Direct storage references never cross file identities.

L1 supplies the upstream replication state, committed-byte export, and incremental application primitives. It accepts Ruby IO objects for streaming transport.

Replication preserves source bytes and profile metadata. It does not perform profile conversion or merge independent writers.

A full replacement is staged into a separate file before replacing a replica. Reopening readers after replacement is explicit. The API does not invalidate live readers by replacing their underlying file.

## Concurrency, durability, and errors

A public database handle supports multiple Ruby threads. Reads use independent positional state. Snapshot reads do not acquire the writer's exclusive file lock.

Writes serialize within the process and across cooperating processes. The writer refreshes committed state after acquiring its exclusive lock.

`lock_timeout:` defaults to five seconds. Contention raises `BusyError` after that timeout. The block has not run when lock acquisition fails.

Closing waits for active operations to finish. Closing from inside that handle's transaction raises `TransactionStateError`.

File commits use upstream-compatible synchronization ordering. A successful transaction returns after its commit is durable. Memory databases retain the same atomic visibility contract without disk durability.

Block failures before publication are known aborts. Commit I/O failures expose `CommitError#outcome`: `:not_committed`, `:committed`, or `:unknown`.

An uncertain outcome never triggers an automatic block retry. The handle requires recovery or reopening before another write.

Library-specific errors inherit `XitDB::Error`. Missing keys, invalid indexes, wrong argument types, and integer overflow use Ruby's corresponding standard error classes.

Profile, format-version, corruption, codec, lifetime, and contention errors have distinct classes. Value errors include an immutable path and preserve their underlying cause.

An example message is `unsupported Symbol at $["profile"]["status"] in portable profile; use a portable value or XitDB::Ruby`.

## Verification and release criteria

1. V1: Verify portable files in both directions against the pinned Zig, Java, TypeScript, and Go implementations.
2. V2: Cover all upstream collection kinds, scalar kinds, signedness, format tags, empty values, occupied nulls, and history layouts.
3. V3: Verify compaction and replication across implementations, including interrupted writes and interrupted replication.
4. V4: Round-trip Ruby types, encodings, key equality, insertion order, custom codecs, and unknown codecs through independent handles.
5. V5: Exercise the public interface for ownership, invalidated views, stable iteration, rollback, contention, reopening, and uncertain commits.

Run integer interoperability cases inside and outside JavaScript's exact integer range. Record receiver limitations separately from binary-format failures.

Test file storage directly. Memory tests supplement file tests and cannot establish durability or cross-process locking.

Run examples with datasets larger than the permitted process memory. Verify incremental lookup, sorted pagination, byte streaming, conversion, and compaction.

Use injected storage failures around publication and synchronization. Confirm the actual recovery result before assigning a commit outcome.

Measure representative read, write, traversal, history, and compaction workloads. Keep file, memory, cold-cache, and warm-cache results separate.

The release requires user-facing documentation for both profiles, their method matrix, their wire contracts, and their supported reference versions.

## Builder decisions and remaining freedom

The designer proposes the runtime floor, profile identifiers, initial Ruby types, strict portable keys, and initial scalar-key subset. These are not prior user instructions.

The designer also proposes ordered native maps, writable transaction iteration, opaque codec values, cross-file conversion, and the five-second writer timeout.

The builder chooses internal class decomposition, buffer sizes, positional IO details, canonical byte layouts, and memoization structures. Those choices must satisfy this document.

The implementation plan records exact Ruby wire encodings before implementation. It also defines the practical memory limits and failure-injection seams.

No product implementation, dependency installation, or project scaffolding is authorized by approval of the approach alone. Implementation follows approval of this design and its implementation plan workflow.

## Reference baseline

The compatibility target is upstream format version 1 at these revisions:

| Reference | Revision |
| --- | --- |
| [Zig implementation](https://github.com/xit-vcs/xitdb/tree/6b93af1af3a260399fa0a0b1b268ded2cbf5eec5) | `6b93af1af3a260399fa0a0b1b268ded2cbf5eec5` |
| [Java implementation](https://github.com/xit-vcs/xitdb-java/tree/905be4a6035975846d4ffe2e76ade8929eaf9d0d) | `905be4a6035975846d4ffe2e76ade8929eaf9d0d` |
| [TypeScript implementation](https://github.com/xit-vcs/xitdb-ts/tree/01ca291fd1a57a2047ee03ca6344abd009480730) | `01ca291fd1a57a2047ee03ca6344abd009480730` |
| [Go implementation](https://github.com/xit-vcs/xitdb-go/tree/86db69bc728d2e9bdd015f9cefa23df40beaab65) | `86db69bc728d2e9bdd015f9cefa23df40beaab65` |

The [upstream introduction](https://xitdb.net/) establishes the collection-oriented, embedded storage model.

The [Java type documentation](https://github.com/xit-vcs/xitdb-java/tree/905be4a6035975846d4ffe2e76ade8929eaf9d0d#types) describes custom tagged byte values.

The [Clojure compatibility documentation](https://github.com/codeboost/xitdb-clj#compatibility-mode-sharing-files-with-other-languages) demonstrates separate native and portable key profiles.

The [TypeScript scalar reader](https://github.com/xit-vcs/xitdb-ts/blob/01ca291fd1a57a2047ee03ca6344abd009480730/src/read-cursor.ts) establishes its integer conversion behavior.
