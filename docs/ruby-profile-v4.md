# Ruby profile version 4 wire contract

The header has hash size 32 and hash identifier `rb04`. Canonical typed keys use SHA-256.
Ruby scalar payloads, canonical keys, indexed envelopes, and record metadata 1 through 8 retain the [version 3 layouts](ruby-profile-v3.md).
Version 4 adds indexed compact pages with integrity checks.
The implementation uses Ruby and existing standard-library operations, with no custom compiled codec or build step.

## Compatibility

Ruby handles reject `rb01`, `rb02`, and `rb03` files without modifying their contents.
This pre-1.0 implementation provides no automatic migration or backward file reader.
Historical format documents describe those files; they remain distinct contracts.
Portable formats and entry points remain unchanged.
The `rb04` identifier is reserved for the Ruby profile, including files that contain only general collections.

## Indexed compact pages

An indexed page contains at most 65,536 bytes, including its checksum.
The row count is between 1 and 1,024; the field count is between 0 and 16.
The physical sequence is:

1. ASCII magic `XR01`.
2. Unsigned variable-length row and field counts, followed by one encoded String schema key per field.
3. Exactly `row_count + 1` unsigned 16-bit row offsets, least significant byte first.
4. Compact scalar cells in row-major schema order.
5. A 32-byte SHA-256 digest of every preceding payload byte.

Counts, schema keys, and scalar cells use the canonical encodings defined for [XP01 pages](ruby-profile-v3.md#typed-page-payload).
Offsets are relative to the first row cell, following the complete offset table.
The first offset is zero; the final offset equals the complete row payload length.
Each accessed pair must be ordered and within the row payload.
A row decoder must consume exactly the byte range between its adjacent offsets.
Zero-length rows are valid when the schema has no fields.
Full decoding validates every boundary and cell, including canonical scalar framing and exact payload exhaustion.

The schema preserves original key bytes, encodings, and order.
Schema keys must be distinct under Ruby String key equality and are frozen after decoding.
Materialized String values are independent and mutable.
Float cells preserve all IEEE binary64 bits, including NaN payloads and negative zero.

## Integrity and selected reads

Readers copy at most the page byte limit plus one byte before rejecting oversized input.
They verify the checksum before interpreting indexed schema or row payloads.
They validate the header, directory endpoints, selected offsets, and requested cells.
Selected reads allocate the schema and requested row without traversing unrelated row cells in Ruby.
They still obtain and hash the bounded page bytes; this is not constant work over an arbitrary byte length.

Ordinary byte damage anywhere in the page fails integrity validation, including damage outside the selected row.
The checksum provides integrity, not authenticity.
A malformed unselected cell with a deliberately recomputed checksum can remain deferred until access or full decoding.
Applications that require complete canonical validation must fully decode the page.
Invalid stored pages raise `InvalidValueError`; invalid argument types retain `TypeError`, and invalid row positions retain `IndexError`.

## Encoding, fallback, and mutation

The writer reserves the offset directory and checksum budget before appending row cells.
Capture retains bound built-in reads, unsupported-shape rejection, and bounded cell allocation from the compact encoder.
If indexed overhead exceeds the page budget, the writer can attempt an `XP01` compact sequential page.
Its decoder retains full validation of skipped cells during selected reads.
Thus a page array may contain both `XR01` and `XP01` byte pages, as well as promoted packed-array pages.
Unsupported schemas, values, or sizes retain general Ruby-profile storage with all supported value types.
Failed page attempts restore transaction checkpoints before fallback.

Compatible updates rewrite one page and its required ancestors, including fresh offsets and checksum.
Incompatible replacements, structural edits, persisted row references, snapshots, compaction, and view lifetimes retain version 3 semantics.
Decoded caches remain operation-local.
