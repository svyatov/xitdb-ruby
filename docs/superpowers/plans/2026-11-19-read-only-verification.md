# Read-only database verification implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a restore process verify the latest committed snapshot of an existing file and locate the first structural defect.

**Architecture:** A dedicated scan owns one read-only descriptor and captures one Core cursor. Core validation follows physical records within the cursor boundary. Profile validation interprets logical values and verifies references in their specific roles. Expose the public entry point only after both layers work.

**Tech stack:** Ruby, the standard library, Minitest, RBS, Steep and the existing Rake tasks.

**Spec:** [Approved verification design](../specs/2026-11-19-read-only-verification-design.md)

## Global constraints

- Open one existing file read-only. Use the captured cursor boundary for every database read.
- Check only the latest committed root and the history path needed to reach it.
- Read byte values in chunks of at most 64 KiB. Check length and remaining budget before allocation.
- Use finite memory, iterative traversal and bounded diagnostic paths. Keep resource exhaustion distinct from corruption.
- Accept portable builtin identifier/width pairs and Ruby `rb05` with width 32. Never invoke an application loader.

## Review focus

1. **R1.** A writer appends a new commit or the pathname starts referring to a replacement file during the scan. Finish against the captured descriptor and boundary (tasks 1 and 5).
2. **R2.** Two arrays expose different ranges of the same physical block. Validate each visible range and allow legal sharing (task 2).
3. **R3.** A valid but large codec payload spans many chunks. Stream it and return one immutable ID for repeated occurrences (task 4).
4. **R4.** A page has a valid checksum but contains a malformed cell in a later row. Fail at that row when identifiable (task 4).
5. **R5.** An index and its ordered entries each parse independently but disagree about membership. Reject the snapshot (task 3).

## File map

Under `lib/xitdb/verification/`, place descriptor capture and dispatch in `scan.rb`, resource accounting in `budget.rb`, physical traversal in `graph.rb`, hash and sorted tree checks in `hash_index.rb` and `tree.rb`, Ruby collection checks in `ruby_collections.rb`, and scalar and page checks in `ruby_values.rb`. Keep the public result and method in `lib/xitdb/verification.rb` and related errors in `lib/xitdb/errors.rb`. Put shared fixture builders and bounded byte edits in `test/support/verification_helpers.rb`. Add RBS declarations alongside each implementation increment, following the existing split between public, Core and Ruby types.

## Task 1. Capture a snapshot and enforce scan limits

- [ ] Write `test/core/verification_scan_test.rb`. In `test_capture_survives_append`, append through a second handle after capture and assert `assert_equal original_bound, cursor.bound`. Cover missing and zero-byte files, both Core versions, invalid trailers, every builtin profile header, unsupported IDs and descriptor closure on exceptions.
- [ ] Run `bundle exec ruby -Ilib:test test/core/verification_scan_test.rb` and confirm failure at the missing capture interface.
- [ ] Implement private `Verification::Scan.open(path) { |scan| ... }` and `scan.read(offset, length) -> String` in `scan.rb`. Open through `Core::FileStore` read-only, reuse Core's checked snapshot, and select the latest entry by bounded history-index descent. Distinguish the virtual empty root from a stored invalid root. Map malformed input at its read site to `VerificationError < CorruptionError` with readers `check`, `offset` and `path`. Preserve filesystem exceptions. Use `UnsupportedVerificationFormatError` for unsupported format/profile combinations.
- [ ] Implement `Verification::Budget` in `budget.rb` with finite limits for stack depth, retained reference contexts, path storage, scalar working bytes and total codec inventory. Cap summaries and cross-index comparison state too. Reserve before retention and release transient usage. Expose internal limit overrides in tests. For each limit assert `assert_equal limit_name, assert_raises(XitDB::VerificationLimitError) { operation.call }.limit`. Bound diagnostic paths by truncation with an explicit omission marker.
- [ ] Rerun the test file. Require zero failures and errors. Commit as `feat(verification): capture a bounded read-only snapshot`.

## Task 2. Verify physical storage and portable values

- [ ] Add `test/core/verification_graph_test.rb`. Assert `assert_nil graph.verify!(root, role: :portable_root)` for all public collection kinds, sparse arrays, tagged bytes and legal sharing. Test R2 in both visitation orders. Mutate one reference, count, digest route, separator or leaf order at a time. Assert the failing check and offset. Include a cycle and a reference reused in an incompatible role.
- [ ] Run `bundle exec ruby -Ilib:test test/core/verification_graph_test.rb` and confirm the missing graph check.
- [ ] Implement `Verification::Graph.new(scan)` and `verify!(root, role:) -> nil`. Use incremental enter/exit frames, active ancestors and completed summaries keyed by interpretation, including visible extent. Validate slot roles, record limits, pointer ranges, inline fields and external byte extents. Keep hash-trie prefix and subtree count checks in `hash_index.rb`; keep linked and sorted tree bounds, separators, ordering and subtree totals in `tree.rb`. Derive counts and key bounds from children. Recheck edge constraints on reuse. Stream portable byte keys through the header's digest algorithm.
- [ ] Rerun the graph tests with zero failures and errors. Commit as `feat(verification): check reachable portable storage`.

## Task 3. Verify Ruby collection layouts and indexes

- [ ] Add `test/ruby/verification_collections_test.rb` covering literal, dictionary, indexed, sorted and paged containers. Include duplicate canonical keys, invalid metadata/arity, dictionary width mismatch, out-of-range order references and R5. In `test_lookup_and_order_disagree`, assert `assert_equal :index_membership, error.check` for a syntactically valid but inconsistent index.
- [ ] Run `bundle exec ruby -Ilib:test test/ruby/verification_collections_test.rb` and confirm failure for missing Ruby-role validation.
- [ ] Implement `Verification::RubyCollections.new(scan, graph)` in `ruby_collections.rb`. Add `:ruby_root` to the graph's accepted root roles. Enumerate child slots with their expected role, count and logical selector. Check record metadata, dictionary identity and canonical ordinary and sorted keys against the current Ruby readers. Check lookup and ordered storage in both directions within the budget. Carry expected row counts to page checks. Stage scalar and page validation in task 4 before exposing verification to callers.
- [ ] Rerun the collection tests with zero failures and errors. Commit as `feat(verification): validate Ruby collection indexes`.

## Task 4. Check scalar envelopes and every page cell

- [ ] Add `test/ruby/verification_values_test.rb`. Exercise builtin scalar wire cases, malformed codec IDs and lengths, and R3 with a loader that raises if called. Assert `assert_equal [id], scan.codec_ids` and `assert_operator largest_payload_read, :<=, 65_536`. Exercise XP01, XR01, XF01 and XA01. For R4, recompute the checksum after changing a later cell. Separately test a bad checksum with `assert_equal page_start, error.offset`, row framing, padding and expected count.
- [ ] Run `bundle exec ruby -Ilib:test test/ruby/verification_values_test.rb` and confirm the missing value checks.
- [ ] Implement `Verification::RubyValues.new(scan)`, `scalar!(slot, path:) -> nil` and `page!(slot, expected_rows:, path:) -> nil` in `ruby_values.rb`. Check codec framing from the bounded byte source, stream opaque data and retain frozen distinct IDs. Apply scalar budgets before materialization, including intermediate numeric and text representations. Reuse page parsers within the 65,536-byte format limit, checking each row and consuming every frame. Preserve the most precise established location. Connect these checks to the Ruby graph roles.
- [ ] Rerun the value and collection test files with zero failures and errors. Commit as `feat(verification): check Ruby wire values and page cells`.

## Task 5. Expose and verify the restore contract

- [ ] Add `test/public/verification_test.rb` through `require "xitdb"`. Assert `assert_equal original_bytes, File.binread(path)` on both success and failure. Cover a read-only source, R1 with a replaced pathname, an ignored unpublished tail, isolated historical damage, a valid empty snapshot, malformed roots, a read failure, and a malformed fixture with two defects where traversal stops at the first. Assert all result fields and deep immutability of strings and the codec ID array.
- [ ] Run `bundle exec ruby -Ilib:test test/public/verification_test.rb` and confirm failure at the missing public method.
- [ ] Add `XitDB.verify!(path) -> XitDB::VerificationResult` to `verification.rb` and load it from `lib/xitdb.rb`. Return `profile`, `hash_id`, `hash_size`, `committed_size` and `codec_ids`. Load Ruby support only when needed. Return only after every required check succeeds. Add the public signatures in `sig/public.rbs`. Document scope, exact limits, exceptions, result interpretation and a restore example in `docs/core.md`. Add the feature to `CHANGELOG.md`.
- [ ] Run the public verification test and `bundle exec rake`. Require zero test failures and passing style, type, coverage and complexity checks. Confirm a plain Ruby process using only `require "xitdb"` verifies one portable and one Ruby file.
- [ ] Commit as `feat(verification): expose latest snapshot verification`.
