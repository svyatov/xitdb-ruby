# Final Ruby storage implementation plan

> **For agentic workers:** Use superpowers:executing-plans. Implement inline in the existing checkout; delegate independent QA and final source review.

**Goal:** Finalize a measured pure Ruby storage implementation satisfying G1 through G5.

**Architecture:** Preserve general value storage and compact scalar cells. Prototype bounded row offsets and page integrity before integrating the measured winner.

**Tech stack:** Ruby >= 3.3, standard library, existing development dependencies.

**Spec:** `docs/superpowers/specs/2026-11-13-ruby-storage-design.md`.

## Global constraints

Preserve G1 completely, the portable profile, operation-local caches, and pure Ruby implementation.
Use the G4 limits declared before measurements. Retain all observations and versioned source provenance.
Keep the existing branch; commit locally; do not push, merge, release, add dependencies, or introduce compiled codecs.
Keep checks separate from timing. Treat Core JSON as a comparison control.

## Review focus

- Hostile input methods, codec callbacks mutating later input, and selector ownership must retain O1 behavior.
- Offset and checksum validation must reject accessed malformed data and state the limits for rechecksummed unaccessed rows.
- Metadata overhead near the page byte limit must fall back with exact data and assignment rollback.
- Nested and numeric fixtures must not disappear from aggregate acceptance checks.
- Compatibility rejection must leave incompatible files unchanged; final measurements must use the integrated library.

### Task 1: Contract and fixtures

**Files:** Design document above; scratch fixture extractor and benchmark sources; archived fixture/provenance under `docs/benchmarks/final-ruby-storage/`.
**Interfaces:** A fixture builder returns independent Array[Hash] datasets identified by `application`, `nested`, `numeric`, and `continuity` with stable SHA-256 hashes.

- [x] Complete builder check and record engineering decisions without reopening authorized implementation scope.
- [x] Capture the crap4ruby snapshot and strictly parse its documented writer grammar. Reject unmatched fields or rows.
- [x] Generate deterministic sizes 58/1,000/10,000, preserving captured scalar types. Derive nested and numeric variants explicitly.
- [x] Verify fixture determinism, ownership, JSON equivalence, source checksum, and original record count. Commit contract and plan locally.

### Task 2: Compact row prototype and controls

**Files:** Scratch `compact_page_encoder.rb`, `compact_page_decoder.rb`, `adapter.rb`, `contract_test.rb`; extracted archived column harness and an exported O1 library.
**Interfaces:** Existing `PageCodec.encode_page(rows)`, `encode_stored_page(rows)`, `decode_page(bytes, expected=nil)`, and `decode_row(bytes,index,expected=nil)` stay unchanged.

- [x] Write failing exact-value, offset, checksum, corruption, limit, and fallback tests against the proposed compact row format.
- [x] Implement shared-schema compact cells, 16-bit row boundaries, and integrity validation with bounded capture and no caller hooks.
- [x] Verify selected traversal touches only the requested row; verify full decoding checks every row. Test recomputed-checksum malformed rows explicitly.
- [x] Run focused public API QA before timing. Preserve unsupported shapes and all general-value semantics.

### Task 3: Balanced selection measurements

**Files:** Scratch `worker.rb`, `benchmark.rb`, `summarize.rb`, `acceptance.rb`; reproducible archive in `docs/benchmarks/final-ruby-storage/`.
**Interfaces:** Worker emits dataset/variant/store/count, exact correctness results, timing/allocation metrics, and three stored-byte measures. Summarizer rejects incomplete or drifting sources and applies every G4 limit per group.

- [x] Compare compact prototype, O1, archived columns, and direct Core JSON for every G3 dataset/size/store group.
- [x] Use two warmups and twelve measured observations, balanced four-variant execution orders, fresh processes, and stable source hashes.
- [x] Require every operation and resource criterion; do not average a failed group into a passing result.
- [x] Investigate failures through profiles or bounded experiments. Revise the candidate without changing predeclared limits, then rerun affected comparisons. No criterion failed in the complete selection run.
- [x] Record the selected format and evidence. Keep raw failed candidates with their source versions. Selection passed all 444 checks.

### Task 4: Production integration and compatibility

**Files:** `lib/xitdb/ruby/page_encoder.rb`, `page_decoder.rb`, `page_codec.rb`, profile/entry-point configuration, `sig/ruby.rbs`, focused Ruby/public tests, and wire documentation.
**Interfaces:** Retain public methods and value semantics. A changed physical format uses a distinct profile identifier, provisionally `rb04`, with explicit rejection of older profiles.

- [x] Write failing public and codec regressions for the selected layout, exact values, snapshots, rollback, hooks, resource boundaries, and compatibility rejection.
- [x] Integrate the measured algorithm with signatures and minimum cohesive implementation changes.
- [x] Update format-aware tests and documentation, preserving historical contracts and archives.
- [x] Run focused tests and `bundle exec rake`; require all tests, 100% typed calls, and CRAP <= 10. Commit a verified increment.

### Task 5: Final evidence and audit

**Files:** `docs/benchmarks/final-ruby-storage/`, current Ruby guide, final wire contract, and this plan.

- [ ] Run independent public API QA covering every review-focus item and bounded resource evidence.
- [ ] Measure the final integrated implementation against the same controls and apply every G4 criterion again.
- [ ] Run final independent source review. Fix important findings with observed failing regressions and rerun required checks.
- [ ] Archive exact sources, fixtures, raw samples, acceptance output, quality-gate evidence, QA, source hashes, and compatibility policy.
- [ ] Extract the archive into a fresh temporary directory; rerun contracts and regenerate identical summaries and acceptance decisions.
- [ ] Commit locally, verify the clean checkout and full G1-G5 requirement audit, remove owned scratch scripts, and mark the goal complete.
