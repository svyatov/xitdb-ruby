# Typed-page encoding experiment

> **For agentic workers:** Use superpowers:executing-plans on the authorized performance branch. Keep this experiment separate from production integration.

**Goal:** Reduce typed-page insert CPU while preserving exact bytes, fallback behavior, and bounded selective operations.

**Architecture:** Reuse identical schema-key objects and cache common Ruby encoding indices. Preserve per-row Hash-behavior checks and the existing wire format.

**Tech stack:** Ruby standard library, the experimental C extension, and the existing replay script. No dependencies.

**Spec:** The active performance goal and `2026-11-07-packed-ruby-records.md` authorize autonomous representation experiments.

## Evidence and alternatives

The first process comparison shows drift in unchanged JSON timings. Same-process comparisons distinguish encoder work from process placement and CPU variation.

H1 skips encoding and byte comparisons when schema keys are identical objects. H2 caches common encoding indices and resolves other encodings through Ruby's API.

Both clear the 5% isolated improvement threshold. H3, reducing buffer writes, remains untested because the first two hypotheses justify a workflow comparison.

Direct Hash-default access is private and deprecated in the installed headers. Keep the supported method calls despite their cost.

## Constraints and review focus

- Preserve String bytes and encodings, Float bits, key order, Hash defaults, subclass rejection, and fallback rollback.
- Preserve 1,024-row and 65,536-byte page limits and selective updates.
- Cover shared keys, distinct equal keys, mismatched encodings, differing key order, and all installed encodings.
- Keep cached encoding indices process-local and initialize them through supported Ruby APIs.
- Compare complete insert/read/update/compact workflows against Core JSON. Report drift and regressions.

## Task 1: Retain and replay the measured encoder

**Files:** `docs/benchmarks/native-encode/`, `script/native_adapter_replay.rb`, and this plan.

**Interface:** Add `--study encode`, with the same page, JSON, Core JSON, and contract replay behavior as `--study decode`.

- [x] Measure H1 and H2 independently through paired encoder calls, retaining exact-byte checks.
- [x] Complete independent public API QA and fresh workflow comparisons.
- [x] Archive candidate sources, baseline sources, raw timings, environment, hashes, and failed measurement attempts.
- [x] Observe `--study encode` fail, then add the option and verify worker and contract replay.
- [x] Review the increment, validate documentation and source digests, and commit the experiment.

Expected: all behavior checks pass; improvements remain supported when unchanged controls share the same process. Production integration remains separate goal work.
