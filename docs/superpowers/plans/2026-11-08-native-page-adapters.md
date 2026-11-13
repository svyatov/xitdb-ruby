# Native page adapter experiment

> **For agentic workers:** Use superpowers:executing-plans to execute this plan in the existing experiment branch. The user authorized autonomous representation experiments.

**Goal:** Determine whether bounded typed pages retain their performance advantage when used through Ruby-profile views and transactions.

**Architecture:** An experimental profile adapter stores flat rows in typed byte pages behind a Core array of page references. Transient row descriptors resolve views without allocating one stored record per row. Sharing a row persists a small record that refers to its page; unsupported updates use ordinary native containers.

**Tech Stack:** Ruby, the existing typed-page C experiment, Core records and arrays. No new dependencies.

**Spec:** The active performance goal and `docs/benchmarks/native-pages/README.md`.

## Constraints

- Work in scratch files until the experiment has measured public API behavior. Keep production library code unchanged during this experiment.
- Bound each page to 1024 rows and 65536 payload bytes. Retain exact scalar bits, String bytes and encodings, and map order.
- Reuse existing transaction, snapshot, locking, rollback, and compaction behavior.
- Fall back for unsupported row types, shapes, and values. Never deserialize arbitrary Ruby objects.
- Clearly separate experimental behavior from production support. No release or dependency change.

## Review focus

- Shared rows must survive source replacement and compaction.
- An unsupported nested update must not load or rewrite unrelated pages.
- Retained views must follow their location and expire after structural edits.
- Rollback must not retain caches keyed only by reused offsets.
- Slices and nested materialization must preserve exact values without repeated page decoding per row.

## Task 1: Connect pages to public native operations

**Files:** Scratch `page_adapter.rb`, `page_array.rb`, `page_row.rb`, `contract_test.rb`, and the extracted typed codec.

**Interfaces:** `PageAdapter.encode(rows, context:, path:)` returns a stored array or nil for fallback. `RowReference` carries a page slot and row index and refuses direct serialization. `PageArray` and `PageRow` implement the existing native collection adapter interface.

- [x] Add a public API contract that fails on the production layout's storage size, then run it without the experimental adapter.
- [x] Add bulk encoding, row lookup, bounded row update, and row sharing. Persist references before any Core serialization.
- [x] Test scalar fidelity, fallback, snapshots, rollback, reopen, compaction, slice assignment, structural edits, and conversion.
- [x] Run an independent public API QA pass and record any unsupported paths.

## Task 2: Measure and preserve the experiment

**Files:** `docs/benchmarks/native-adapters/`, a replay command if the experiment warrants retention, and this plan.

- [x] Compare public insert, whole-value read, indexed read, update, and compaction with the same JSON workflow. Keep correctness checks identical inside timings.
- [x] Preserve sources, raw observations, commands, environment, and limits. Report absolute timings, byte counts, and variability.
- [x] Validate replay and source integrity, then commit the experiment as one coherent increment.

## Production decision

Production integration requires validated malformed-page handling, a deliberate file-profile identifier, extension packaging and fallback policy, RBS coverage, the full `bundle exec rake` gate, and package verification. A successful experimental benchmark alone does not satisfy these requirements or complete the active goal.
