# Ruby input and layout optimization plan

> **For agentic workers:** Use superpowers:executing-plans. Implement in this session; use independent QA and final source review.

**Goal:** Implement O1, then evaluate O2 and O3 together with measured Ruby-only prototypes.

**Architecture:** Read exact Array, Hash, and String contents through bound built-in methods. Copy strings before calling normal methods on them. Keep general storage and extended scalar validation. Explore bulk numeric encoding with direct row offsets in a separate bounded-page prototype.

**Tech stack:** Ruby >= 3.3, standard library, existing dependencies. No custom native extension or added dependencies.

**Spec:** The user selected O1 followed by joint O2/O3 exploration after allowing API and format changes. Built-in object overrides become ignored input behavior. This replaces their blanket rejection for exact Arrays, Hashes, and Strings. The prior all-six benchmark remains the comparison workload, not a promise of parity.

## Global constraints

- Preserve exact Float bits, string bytes and encodings, canonical key identity, and insertion order.
- Preserve snapshots, rollback, view lifetimes, application codec dispatch, and bounded traversal of cyclic or deep input.
- Reject unsupported subclasses, keys, Hash defaults, and identity comparison without calling input hooks.
- Keep the portable profile contract and extended scalar validation unchanged.
- Keep caches operation-local. Do not add an internal ObjectSpace API or compiled codec.
- Work on the existing performance branch. Commit verified increments locally; do not push, merge, or release.

## Review focus

- Frozen, private, prepended, or undefined input methods must never run during built-in capture.
- Keys used for lookup, retained views, streaming, and copy paths must be owned without calling copy hooks.
- Application callbacks may mutate later inputs; cached values must reflect actual contents at each traversal point.
- Unsupported nested shapes must fall back without losing data or bypassing cycle detection.
- Direct row offsets must reject malformed accessed records and retain bounded work; prototype corruption rules must be explicit.

### Task 1: Built-in input capture

**Files:** Add `lib/xitdb/ruby/input.rb` and `test/ruby/builtin_input_test.rb`. Update Ruby profile, page encoding, key/scalar encoding, affected selector ownership, signatures, tests, and input documentation.

**Interfaces:** `Ruby::Input.check!(value, path: [])` skips method inventories only for exact Array, Hash, and String. `Ruby::Input.string(value)` copies exact String bytes and encoding through bound methods. Input iteration binds Array/Hash methods with blocks, avoiding enumerators that redispatch overridden methods. General scalar and codec validation retain `InputGuard`.

- [x] Add public tests for hostile built-in values, keys, page fallback, cycles, snapshots, and rollback. Run `bundle exec ruby -Ilib:test test/ruby/builtin_input_test.rb`; expect failures from rejected overrides.
- [x] Implement bound capture and update former rejection tests to assert stored contents and zero callbacks. Keep unsupported-type rejection tests.
- [x] Run focused tests, then `bundle exec rake`; expect all quality gates to pass.
- [x] Run independent public API QA, then source review. Fix important findings with failing regressions.
- [x] Measure production CPU, elapsed time, allocations, and bytes across all six benchmark groups. Record provenance and limitations.
- [x] Commit the verified input change and reproducible measurements.

### Task 2: Joint bulk and indexed page experiment

**Files:** Scratch Ruby scripts first; archive reproducible sources and results under `docs/benchmarks/`.

**Interfaces:** Prototype exact flat-row page encode, full decode, selected-row decode, and numeric update. Use shared schemas, bulk `pack`/`unpack`, fixed-width offsets, and bounded row framing. Keep a generic fallback for unsupported shapes. These are experiments, not production format changes.

- [ ] Build a Ruby-only prototype with correctness checks for exact values, boundaries, malformed offsets, and independently validated selected rows.
- [ ] Compare against the committed O1 page implementation and Core JSON with balanced samples at 58, 1,000, and 10,000 rows.
- [ ] Record gains, losses, storage growth, corruption-detection trade-offs, and whether production integration is justified.
- [ ] Commit the reproducible experiment and decision. Do not claim the original parity target without a complete production comparison.
