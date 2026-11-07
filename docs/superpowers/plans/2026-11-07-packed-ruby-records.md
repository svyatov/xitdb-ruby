# Packed Ruby records implementation plan

> **For agentic workers:** Use superpowers:executing-plans for this authorized autonomous task. Follow each test cycle before committing production changes.

**Goal:** Reduce retained native storage and bulk-operation costs while preserving exact Ruby values and bounded selective operations.

**Architecture:** Prototype compact records, bounded construction, and shared field dictionaries against existing collection trees. Keep transaction publication and durability in Core.

**Tech stack:** Ruby 3.3 or later, standard library, Minitest, RBS, Steep, and repository verification scripts.

**Spec:** The user's November 7 compact-storage instruction replaces the earlier rb01 compatibility requirement.

## Global constraints

- API and storage-format breaks are allowed. No migration or rb01 reader is required.
- Preserve supported Ruby values, numeric bits, String encodings, canonical key equality, and insertion order.
- Preserve snapshots, rollback, writer coordination, and durability.
- Keep traversal and maintenance bounded for deep collections and oversized values.
- Selective operations must avoid materializing unrelated large collections.
- Keep crap4ruby unchanged. Add no dependencies. Publish no release.
- Run the full seven-sample alternating matrix only after implementation stabilizes.
- Distinguish historical measurements from fresh paired comparisons.

## Review focus

- Equal keys with different original representations retain the first stored key and its position.
- Builder promotion and failed codecs leave roots, snapshots, and transaction cursors unchanged.
- Malformed counts, duplicate keys, cycles, and out-of-bound references fail within captured read bounds.
- Deep traversal and oversized scalars retain bounded buffers during encoding, conversion, and compaction.
- Small nested updates copy only their record or bounded chunk and the required ancestor path.

## Task 1: Preserve the interrupted comparison

**Files:** `docs/benchmarks/native-records/rb01-*` and `pkg/native-rb01-final-partial.json`.

- [x] Stop the matrix and verify its worker exits.
- [x] Preserve completed results with counts, revisions, hashes, and partial-case limitations.
- [x] Commit the historical artifacts independently at `7a40793`.

## Task 2: Measure working prototypes

**Files:** Scratch prototype sources under `/tmp`, `script/native_benchmark.rb`, and prototype evidence under `docs/benchmarks/native-records/`.

**Interface:** Preserve the public benchmark's transaction, view, history, reopen, and compaction operations.

- [x] Build a scratch copy of candidate `fde9a5d`.
- [x] Add a trial compact record: metadata u32, field count u32, then consecutive nine-byte slots.
- [x] Store bounded small maps as original-key/value pairs without separate indexes.
- [x] Build arrays from bounded groups of sixteen slots, writing completed tree blocks once.
- [x] Compare indexed construction, packed records, and packed records with the bounded builder.
- [x] Compare projected inline-cell and chunk costs with measured records. Chunk alternatives remain unimplemented.
- [x] Measure fixture, 1,000-record, and 10,000-record cases in memory and reopened files.
- [x] Record latency, allocations, retained bytes, byte traffic, and history growth for every requested operation.
- [x] Include portable and complete JSON workflows as controls.
- [x] Archive prototype sources, raw results, and the selection rationale before production implementation.

## Task 3: Implement the selected representation with regression tests

**Files:** `lib/xitdb/core/`, `lib/xitdb/ruby/`, `lib/xitdb/profiles/ruby.rb`, `sig/`, and matching tests.

**Selection gate:** Finish targeted validation and scalar-sharing probes. Archive their sources, results, and design rationale before production changes.

**Interface:** Keep public transactions and views. Add bounded Core records and private Ruby adapters behind profile construction.

### Task 3.1: Bounded records

- [x] Test `Core::Record.append(transaction, metadata:, fields:)` and `Core::Record.read(database, slot, bound:)`.
- [x] Limit records to 32 fields. Validate unsigned metadata, slot tags, counts, and captured bounds.
- [x] Add `:record` after existing Core tags. Preserve existing numeric tag assignments.
- [x] Teach compaction to reserve records before remapping fields, preserving cycles and sharing.
- [x] Test malformed counts, unknown child tags, truncated records, snapshots, and compaction.
- [x] Add RBS declarations. Run focused tests, style, typing, and the suite before committing.

### Task 3.2: Compact maps and sets

- [ ] Add `Ruby::PackedMap < Containers` for maps and sets with at most sixteen members.
- [ ] Store original key slots in order. Compare canonical identities without separate persistent indexes.
- [ ] Implement lookup, assignment, deletion, clearing, ordinal traversal, and promotion.
- [ ] Promote oversized keys or the seventeenth member to existing indexed `Containers`.
- [ ] Bound decoded key payloads before decoding. Reject duplicate canonical identities and invalid set values.
- [ ] Preserve the first original key on replacement. Append a deleted key when inserted again.
- [ ] Test both stores, encoding distinctions, signed zero, promotion, rollback, failure injection, and old snapshots.
- [ ] Select `rb02` in native handles. Reject `rb01` through ordinary profile mismatch checks.
- [ ] Keep existing indexed, sorted, and linked adapters. Their internal envelopes can remain within `rb02`.

### Task 3.3: Compact arrays and bounded construction

- [ ] Add `Core::ArrayBuilder.new(transaction)`, `append(slot)`, and `slot` with sixteen slots per active level.
- [ ] Test boundaries through 10,000 elements, empty input, invalid slots, ended transactions, and repeated finalization.
- [ ] Add `Ruby::PackedArray < Containers` with inline slots through sixteen elements.
- [ ] Store larger arrays as a compact record referencing the existing Core array tree.
- [ ] Implement insertion, deletion, truncation, slices, concatenation, and normalized traversal.
- [ ] Use the builder only during unpublished encoding. Existing selective updates use Core copy-on-write paths.
- [ ] Test deep inputs, sparse public assignments, threshold transitions, snapshots, and aborted construction.

### Task 3.4: Dictionaries and operation state

- [ ] Add private `Ruby::PackingState` with bounded encoded scalar and schema tables.
- [ ] Pass state explicitly through profile construction and materialization. Avoid shared context caches.
- [ ] Bound scalar sharing to 256 exact short names or Strings and schema sharing to 64 shapes per operation.
- [ ] Reuse canonical identities for at most 256 validated frozen String key objects per encoding operation.
- [ ] Carry state into input Enumerators explicitly. Fiber-local state alone misses their validation calls.
- [ ] Include scalar type, String encoding, and exact bytes in shared identities.
- [ ] Store schema maps as one schema slot followed by ordered value slots.
- [ ] Cache decoded schema keys only within read-only materialization. Transaction reads remain uncached.
- [ ] Reuse existing schemas for value updates. Key changes can publish ordinary compact maps.
- [ ] Test concurrent and reentrant reads, codec errors, rollback offset reuse, cache limits, and independent decoded Strings.

### Task 3.5: Measured encoding costs

- [ ] Test exact immediate scalar classes and rejection of singleton, private, removed, or overridden object methods.
- [ ] Remove duplicate checks after profile input validation. Keep validated scalar dispatch owned by the profile.
- [ ] Keep guards on direct scalar encoding and map key entry points.
- [ ] Derive stored key identities from validated built-in decoders without repeating application-object introspection.
- [ ] Stream String, Symbol, and codec prefixes into byte storage without concatenating entire payload copies.
- [ ] Test exact scalar wire bytes and bounded append requests for oversized values.

### Task 3.6: Contract and verification

- [ ] Document `rb02`, record metadata, validation, limits, and intentional interoperability changes.
- [ ] Update structural fixtures and provenance for the selected format.
- [ ] Run all public behavior tests, quality gates, package checks, reference tests, and Linux memory checks.

## Task 4: Verify and publish reproducible evidence

**Files:** Benchmark drivers, `docs/native-profile-performance.md`, and compressed raw evidence.

- [ ] Run focused tests, then the repository quality and package gates.
- [ ] Run affected reference interoperability and Linux memory checks.
- [ ] Stabilize the candidate before running seven measured alternating pairs with excluded warmups.
- [ ] Compare against original baseline history, optimized rb01, portable records, and JSON workflows.
- [ ] Publish absolute values, ratios, byte accounting, update amplification, limits, and remaining bottlenecks.
- [ ] Review the completed change and remove temporary experiment scripts.

The user authorized autonomous execution. Representation and API experiments require no additional approval.
