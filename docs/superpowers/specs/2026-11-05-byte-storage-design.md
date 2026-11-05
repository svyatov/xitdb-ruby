# Byte storage consolidation

Status: D1 selected by the user on 2026-11-05. Written design awaiting review.

## Intent

Give physical byte values one implementation behind `XitDB::Core::Bytes`.
Logical conversion must access payloads without calculating file offsets or constructing physical records.
This is an internal refactor of the implementation at `b2de0f8`.

The architecture assessment covered 46 runtime files and found localized Information Leakage in byte storage.
`Core::Database`, `Core::Bytes`, and `Conversion::ByteSource` encode overlapping rules for lengths, inline data, and format tags.
Changing validation requires a maintainer to inspect each path.
The collection trees, profile encodings, and locking modules remain separate.

## Goals and limits

- Preserve existing supported interfaces, upstream format version 1, and the `rb01` representation.
- Preserve scalar inline selection, external conversion records, and compaction record representation.
- Keep bounded transfers at 65,536 bytes and file write buffers at 2 MiB.
- Keep MRI Ruby 3.3 and later, existing dependencies, and caller-owned resources.
- Change neither transaction publication nor directory synchronization.
- Add no supported application interface or general transfer framework.

The approved [project design](2026-11-04-xitdb-ruby-design.md) remains binding.
The [Ruby wire contract](../../ruby-profile-v1.md) remains unchanged.

## Approaches

| Design | Interface shape | Trade-off | Decision |
| --- | --- | --- | --- |
| D1 | Captured byte source plus one writer in `Core::Bytes` | Small interface with explicit representation policy | Selected by the user |
| D2 | Database-owned metadata, range-read, and append methods | Avoids a source object but repeats metadata validation | Rejected |
| D3 | ByteRange with slicing, iteration, materialization, storage, and relocation | More operations and state rules for callers | Rejected |
| D4 | Retain the implementation | Avoids refactor risk but retains distributed format knowledge | Not selected |

## Selected interface

These are internal operations. Existing entry points remain compatible.

```ruby
XitDB::Core::Bytes.open(database, slot, bound:) # => internal Source
source.size                                  # => Integer
source.format_tag                            # => frozen binary String or nil
source.read(position, length)                # => binary String

XitDB::Core::Bytes.append(
  transaction,
  size:,
  format_tag: nil,
  prefix: "".b,
  representation: :automatic
) { |position, length| ... }                 # => Core::Slot
```

`size` describes the supplied payload, excluding `prefix`.
The block returns exactly the requested payload bytes.
Positions are relative to that payload, excluding `prefix` and physical metadata.

The writer requests ascending, non-overlapping ranges of at most 65,536 bytes.
An empty payload invokes no read block.
It writes prefix, payload, and optional format tag in that order.
The prefix is also transferred in bounded chunks.
Callers keep source data and the prefix stable during the call.
The writer neither mutates nor retains caller inputs.

`:automatic` retains the scalar rules: at most eight untagged bytes or six tagged bytes, with no NUL byte.
Values outside those rules use external storage.
`:external` always creates an external record, including for empty or short payloads.
An automatic candidate containing NUL bytes must reuse its captured bytes during external storage, without repeating source reads.

## Read contract

`open` accepts `:bytes` and `:short_bytes` slots.
It captures the supplied bound and validates the complete record, including its optional two-byte tag.
Opening an external value reads metadata without materializing its payload.
Inline parsing happens inside `Core::Bytes`, without calling `Database#read_bytes` recursively.

The source captures immutable size, tag, bound, and private location metadata.
Its interface exposes no physical offsets.
Each read checks the database remains open, including inline and zero-length reads.
It uses the captured bound rather than a later committed size.

Read positions and lengths must be Integers.
Wrong argument types raise `TypeError`.
Negative or excessive logical ranges raise `InvalidValueError` with `truncated byte payload`.
A zero-length read at payload end succeeds.
Malformed physical extents retain `CorruptionError`; closed handles retain `ClosedError`.

Explicit full reads may allocate the complete payload, as `Database#read_bytes` already does.
Streaming callers request bounded chunks.
The source does not acquire ownership of a database handle or transaction.
Context admission, transaction lifetime, thread checks, and stream expiry remain with their existing callers.

## Write contract

The writer uses the supplied active transaction.
It owns inline selection, length encoding, tag placement, slot construction, and bounded transfer.
It validates arguments before appending data or invoking the source block.

Sizes must be nonnegative Integers, and prefixes must be Strings.
Wrong size or prefix types raise `TypeError`; negative sizes and unknown representation policies raise `ArgumentError`.
Invalid tags raise `ArgumentError`: non-nil tags must be two-byte Strings, matching `ByteValue` validation.
A combined payload size outside the unsigned 64-bit storage range raises `RangeError`.

A missing or short block result raises `EOFError`; a non-String result raises `TypeError`.
An oversized result raises `ArgumentError` before that result is appended.
Original source and store exceptions propagate unchanged.
The writer performs no retry, checkpoint, truncation, publication, synchronization, or resource closure.
Existing transaction owners handle incomplete appends.

## Cohesion

Single responsibility: represent byte values in physical storage.

`Core::Bytes` owns physical lengths, locations, inline capacities, NUL termination, format-tag placement, and transfer bounds.
Keep its implementation in `lib/xitdb/core/bytes.rb`, with a private source type.

Profiles retain scalar payload parsing, encoding names, unsigned Ruby fields, and UTF-8 classification.
`Conversion` retains traversal, transforms, and logical slice positions.
`Streams::Reader` retains IO position, buffer, EOF, admission, and expiry rules.
Compaction retains graph traversal and offset-map identity.
The storage and transaction modules retain locking, publication, rollback, and directory synchronization.

## Compatibility and migration

Retain `Database#bytes`, `Database#read_bytes`, `Core::Bytes.locate`, and `Core::Bytes.copy`.
Their supported inputs, return shapes, scalar freezing, and error behavior remain compatible.
`locate` retains its untagged-only check and String-or-offset return shape for existing callers.
New internal callers use the captured source rather than that representation-dependent result.

`copy` retains its small-value branch and accepts progressing short IO reads for larger transfers.
It must not turn an ordinary short read into premature EOF.
Characterize those compatibility cases before replacing its implementation.

`Conversion::ByteSource` retains its caller interface, logical slicing, unsigned-field parsing, and encoding classification.
Its physical reading and writing delegate to `Core::Bytes`.
Conversion requests `:external` explicitly, including for empty values.

`Streams::Reader` rejects non-byte or tagged slots before opening the source, preserving its existing rejection order.
Its complete logical reads remain admitted through the Context.

Compaction copies external records with `:external` and preserves optional tag bytes.
Inline slots still pass through unchanged.
The offset map continues to preserve shared external records.
No Ruby codec runs while copying physical bytes.

Whole-file byte equality is not required across separate databases with different generated identities.
Scalar slot choices and copied record contents remain the compatibility checks.

## Dependencies and verification

Dependency category: local-substitutable.
Use the existing memory, file, and fault-injecting storage adapters through real database transactions.
Add no port, dependency, or application configuration.

Test the shared interface for representations, tags, captured bounds, malformed extents, chunk limits, and failures.
Keep end-to-end scalar, conversion, streaming, and compaction tests for their separate behavior.
Remove only redundant implementation-specific tests after identifying equivalent coverage.
No existing test has been identified for removal during design.

Run focused tests during each migration.
After the final task, run the fast/package gates on Ruby 3.3, 3.4, and 4.0 once per runtime.
Run the pinned reference matrix and a fresh 256 MiB Linux memory gate on the final implementation.
Retain actual logs and reports at their measured revision.
Historical measurements establish no result for the refactor.

## Builder choices

The designer selected the internal operation names, callback contract, validation errors, and task order.
The user selected D1; these details are proposed for review rather than attributed to the user.
Private parser decomposition and compatibility-wrapper mechanics remain implementation choices.
Keep those choices inside `Core::Bytes`; do not add a second physical byte implementation.
