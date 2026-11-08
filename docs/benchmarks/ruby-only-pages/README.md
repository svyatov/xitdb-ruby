# Ruby-only page baseline

Commit `3085ce4` replaces the compiled page codec with Ruby and removes the extension build. This measurement uses that production implementation. It does not meet the performance target in any of the six groups.

Every median CPU comparison is slower than Core JSON. Inserts take about 40 to 1,834 times as much CPU time; updates take 36 to 497 times as much. The current design requires substantial performance work.

## Workload

The fixture has six fields per row: three Strings, an Integer, and two nil values. Each group has two excluded warmups and twelve measured samples. The driver rotates all six orders of the Ruby profile, direct Core JSON, and public JSON controls.

The operations insert all rows, read all rows, read three selected rows, update one numeric field, and compact the database. Each worker checks inserted values, reads, updates, snapshots, and compaction. File workers also check reopening.

There are 216 measured observations and 36 warmups. All correctness, dataset identity, sample-count, stable-size, and source-drift checks pass. The raw variant name `native` identifies the Ruby value profile, not a compiled implementation.

## CPU time

Values are median paired ratios of Ruby-profile CPU time to Core JSON CPU time. A ratio greater than 1 is slower. The summary also retains absolute medians, ranges, allocations, and individual win counts.

| Rows | Store | Insert | Read all | Read three | Update | Compact |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 58 | File | 39.76 | 4.21 | 6.39 | 36.18 | 1.62 |
| 58 | Memory | 89.92 | 4.27 | 6.53 | 70.35 | 1.66 |
| 1,000 | File | 475.50 | 6.21 | 17.24 | 355.54 | 1.54 |
| 1,000 | Memory | 836.91 | 5.83 | 19.06 | 497.00 | 1.33 |
| 10,000 | File | 1448.12 | 6.51 | 2.88 | 79.41 | 1.06 |
| 10,000 | Memory | 1833.88 | 6.54 | 3.12 | 94.82 | 1.05 |

## Elapsed time

These are median paired elapsed-time ratios, reported separately from CPU time.

| Rows | Store | Insert | Read all | Read three | Update | Compact |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 58 | File | 50.04 | 5.13 | 8.86 | 36.49 | 1.50 |
| 58 | Memory | 148.92 | 5.49 | 8.64 | 99.29 | 2.49 |
| 1,000 | File | 491.92 | 6.14 | 21.92 | 399.01 | 1.89 |
| 1,000 | Memory | 1102.14 | 5.85 | 24.86 | 493.55 | 1.11 |
| 10,000 | File | 1708.30 | 7.51 | 2.89 | 86.49 | 1.10 |
| 10,000 | Memory | 1882.38 | 6.51 | 2.64 | 106.74 | 1.41 |

## Storage

Both stores produce the same byte counts. Initial bytes, appended update bytes, and compacted bytes are measured separately.

| Rows | Initial | Appended by update | Compacted |
| ---: | ---: | ---: | ---: |
| 58 | 3,217 | 2,973 | 3,218 |
| 1,000 | 45,098 | 44,854 | 45,099 |
| 10,000 | 455,217 | 47,058 | 455,218 |

## Verification and limits

The complete `bundle exec rake` gate passes 531 tests and 42,550 assertions, style, RBS, Steep, 100% typed-call coverage, and the CRAP threshold. Line coverage is 97.98%; branch coverage is 89.09%.

Independent runtime QA covers 103 encodings, exact Float payloads, malformed pages, callbacks, fallback, persistence, and decoder boundaries. Source review found a decoder input-hook defect; failing regressions reproduced it before the fix. The full gate and bounded follow-up QA pass after that fix.

Evidence covers Ruby 4.0.9 on Darwin arm64. Other platforms, other Ruby versions, crash injection, and isolated-host timing are not established by this run. CPU and elapsed results are both retained because external load can affect timing.

## Replay

`provenance.json` identifies the commit and hashes every library source and archive. `samples.json.gz` contains raw observations; `summary.json.gz` contains aggregates. `harness.json.gz` contains the executable Ruby scripts in its `files` mapping.

1. Extract that mapping into a scratch directory and check out the recorded commit.
2. Run `ruby /scratch/ruby_benchmark.rb /checkout /scratch/samples.json`.
3. Run `ruby /scratch/summarize.rb /scratch/samples.json /scratch/summary.json`.

Output paths must not exist. No compiler or extension build is required. The driver rejects compiled gem contents and checks that codec entry points come from Ruby files.
