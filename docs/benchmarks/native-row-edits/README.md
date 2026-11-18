# Numeric page-row edits

Commit `bc771fa` avoids writing a temporary packed map when replacing an existing page-row field with an Integer, Float, or nil.

The operation carries an edited row to its parent. Typed pages consume it directly; other parents persist it through ordinary profile encoding.

Logical roots retain ordinary map promotion because they have no parent. Storage format `rb03`, snapshot behavior, and generic fallback remain unchanged.

## Measurements

The comparison uses the [production workload](../native-production/README.md) and the original methods from `e6edf81`. All variants use the native input guard.

Each group receives two excluded warmups and twelve measurements. All six variant orders repeat twice in one process after tests and runtime QA stop.

The table reports median process CPU milliseconds for one field update.

| Rows | Store | Original | Candidate | Core JSON |
| ---: | --- | ---: | ---: | ---: |
| 58 | File | 1.997 | 1.559 | 0.359 |
| 58 | Memory | 1.168 | 0.913 | 0.201 |
| 1,000 | File | 2.254 | 1.867 | 0.725 |
| 1,000 | Memory | 1.468 | 1.216 | 0.568 |
| 10,000 | File | 2.473 | 2.053 | 4.704 |
| 10,000 | Memory | 1.572 | 1.313 | 4.278 |

The update appends 2,973 bytes at 58 rows, 44,854 bytes at 1,000 rows, and 47,058 bytes at 10,000 rows.

Those sizes save 360, 360, and 361 bytes respectively. Compacted sizes remain 3,218, 45,099, and 455,218 bytes.

All observations check full values, selected rows, previous snapshots, compaction, and file reopening. Byte sizes are stable within each group.

The target remains unmet: small updates and all insert groups lose to Core JSON. No benefit is claimed for unchanged operations.

## Verification

The full gate passes 524 tests and 42,502 assertions, style checks, RBS, Steep, 100% typed calls, and the complexity threshold.

Independent QA compares twelve scenarios and 120 exploratory actions against the base. It covers encoded keys, Float bits, copied rows, promoted parents, rollback, callbacks, and reopening.

Source review identifies a valid row-reference root that lacks a parent to persist its edit. The regression reproduces a read-boundary error during location refresh.

Disabling the shortcut for logical roots fixes that failure. Independent follow-up verifies ten root-value cases, merges, rollback, view expiration, and reopening.

Runtime evidence is limited to Ruby 4.0.9 on Darwin arm64. Scheduling and filesystem caches remain uncontrolled.

## Replay

`provenance.json` records source, binary, and artifact hashes. Raw samples include CPU, elapsed time, allocations, byte counts, and correctness results.

Extract the `files` mapping from `harness.json.gz` using the procedure in the production benchmark.

1. Build the recorded candidate checkout with `bundle exec rake compile`.
2. Run `ruby /scratch/production_row_benchmark.rb /checkout /scratch/samples.json`.
3. Run `ruby /scratch/guard_summary.rb /scratch/samples.json /scratch/summary.json`.

The driver switches the three changed methods between captured production implementations and archived original implementations. It omits redundant constant declarations when loading the originals.

Output files must not exist. Source drift, missing observations, inconsistent dataset identities, or unstable byte sizes fail the driver or summarizer.
