# Root cursor reads

Commit `9c29066` avoids allocating traversal state when a cursor has no parent. Database, transaction, and cursor validity checks still run.

The comparison uses the [production workload](../native-production/README.md), with the original method from `8d4d645` as its baseline.

The candidate and Core JSON control both use the optimized Core method. Each group has two excluded warmups and twelve measurements in balanced orders.

The table reports median process CPU milliseconds for one field update.

| Rows | Store | Original | Candidate | Core JSON |
| ---: | --- | ---: | ---: | ---: |
| 58 | File | 1.543 | 1.389 | 0.337 |
| 58 | Memory | 0.896 | 0.837 | 0.191 |
| 1,000 | File | 1.925 | 1.779 | 0.750 |
| 1,000 | Memory | 1.210 | 1.141 | 0.567 |
| 10,000 | File | 2.086 | 1.908 | 4.715 |
| 10,000 | Memory | 1.328 | 1.262 | 4.260 |

Storage sizes remain unchanged. All six cases must match Core JSON to meet the performance target; this change does not meet that target.

## Verification

The full gate passes 525 tests and 42,508 assertions, style, RBS, Steep, typed-call coverage, and the complexity threshold.

Independent QA produces identical results for twelve scenarios against the original method. These include rollback, cursor expiration, threads, deep paths, callbacks, and reopening.

Source review reports no defects. Runtime evidence covers Ruby 4.0.9 on Darwin arm64; process contention and crash injection are outside this check.

## Replay

`provenance.json` records source, binary, and artifact hashes. Raw samples include CPU, elapsed time, allocations, byte counts, and correctness results.

Extract the `files` mapping from `harness.json.gz` using the production benchmark procedure.

1. Build the recorded checkout with `bundle exec rake compile`.
2. Run `ruby /scratch/production_cursor_benchmark.rb /checkout /scratch/samples.json`.
3. Run `ruby /scratch/guard_summary.rb /scratch/samples.json /scratch/summary.json`.

The driver requires local Git history containing `8d4d645`. It switches only `Cursor#slot` and includes the baseline source in its output.

Output paths must not exist. Source drift, missing observations, inconsistent dataset identities, and unstable byte sizes fail verification.
