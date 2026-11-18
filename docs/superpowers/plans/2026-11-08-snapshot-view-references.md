# Snapshot view references

> **For agentic workers:** Use superpowers:executing-plans on the existing experiment branch. Autonomous implementation is authorized by the active performance goal.

**Goal:** Remove ancestor traversal from reads through retained snapshot views while preserving live transaction locations.

**Architecture:** Pass the resolved immutable `Core::Slot` from `Context#view` to `Views::Base`. Retain it only without a transaction. Keep lifetime checks and captured bounds on every read.

**Tech stack:** Ruby 3.3 or later, Minitest, RBS, and the repository quality gate. No dependencies or format change.

**Spec:** The active performance goal and the invariants in `2026-11-07-packed-ruby-records.md`.

## Constraints and alternatives

- Snapshot contexts own immutable roots and captured bounds. Their child references remain stable across later commits.
- Transaction views must resolve locations after updates and expire after structural changes or transaction completion.
- Keep storage-open checks and operation guards. Retain no adapter, mutable value, or cross-context cache.
- A slot costs one retained immutable descriptor per view. Avoid adapter caching because it retains more state and complicates concurrent reads.
- Duplicate experimental profile dispatch and compiled encoding checks are separate costs, deferred from this change.

## Review focus

- Snapshot views remain correct after source replacement, rollback, compaction, and file reopening.
- Closed databases and ended transactions still reject retained views.
- Live descendant views reflect value replacement and expire after ancestor replacement.
- Slices and reference sharing retain their source bounds and identity.
- Concurrent readers share only immutable references.

## Task 1: Retain immutable snapshot references

**Files:** `lib/xitdb/context.rb`, `lib/xitdb/views/base.rb`, `sig/public.rbs`, and `test/public/snapshot_reference_test.rb`.

**Interface:** Add optional `slot: Core::Slot?` to the internal base-view constructor. `Context#view` supplies its resolved slot. Transaction contexts ignore it.

- [x] Add a public regression that compares retained leaf reads at depths one and forty in portable and Ruby profiles.
- [x] Run the regression and observe excess storage reads before the change.
- [x] Retain snapshot slots, update signatures, and preserve all lifetime checks.
- [x] Test later commits, rollback, live transaction updates, structural expiration, slices, and closed handles.
- [x] Run focused tests and `bundle exec rake`, then independent QA and review.
- [x] Compare fresh baseline and candidate timings. Commit the verified code and evidence.

This improves a shared read path. It does not integrate typed pages or complete the broader performance goal.

Evidence: [retained snapshot references](../../benchmarks/snapshot-references/README.md). The full gate passes 491 tests and 41,676 assertions. Independent QA and source review find no defect.
