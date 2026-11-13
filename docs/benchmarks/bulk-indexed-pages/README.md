# Bulk columns and direct row offsets

Keep O1 in production. Do not integrate this combined page format.
The XP02 prototype improves selected reads but increases insert CPU, full-read CPU, allocations, and stored size on the measured dataset.
Direct row access merits a separate experiment that retains compact cells.
These results do not reject bulk numeric encoding for other datasets.

## Design

The Ruby-only prototype stores one ordered schema, a column directory, and independently addressable column payloads.
Integer columns use `pack("q<*")`; Float columns use `pack("G*")`.
Full reads unpack numeric blocks in bulk.
Each nullable numeric column also contains one presence byte per row.
String columns share an encoding name and store fixed-width offsets into a byte payload.
Boolean columns use one byte per cell; all-nil columns have no payload.

Pages retain the limits of 1,024 rows, sixteen fields, and 65,536 encoded bytes.
Encoding stops before captured String keys and values exceed a 65,536-byte raw budget.
Temporary arrays, numeric blocks, and output copies require additional memory; no peak-memory bound was measured.
Mixed column types, incompatible String encodings, nested values, oversized pages, and unsupported shapes use the O1 fallback.
The scratch adapter selects XP02 first, then XP01 or general collections.
No production library or portable format changed.

Selected reads validate dimensions, schema, column framing, and requested cells without scanning unrelated cells.
Numeric access uses a fixed position; String access reads adjacent offsets.
Full reads validate every cell.
Unaccessed cell corruption can remain undetected until that cell is read or the page is fully decoded.
Each read still obtains and copies a bounded page byte String; direct access removes Ruby-level cell traversal.
Updates decode and rewrite one page, preserving snapshot behavior through Core.
No decoded cache survives an operation.

## Method

The comparison uses production commit `6d26b1d` for O1 and Core JSON.
The prototype loads only inside its own worker processes through the archived adapter.
All variants use the same records and public database workload as the [O1 measurements](../ruby-input-capture/README.md).
Rows contain three Strings, an Integer, and two nil values.

Each size and store has two excluded warmups and twelve measured observations per variant.
All six orders rotate evenly across measured samples.
Fresh workers exclude startup and explicit GC from operation timing.
No other project runtime checks or benchmarks ran during measurement.
Every worker verifies insert, full and selected reads, numeric update, snapshot, compaction, and file reopening where applicable.
The driver verifies unchanged production and harness sources.
The summarizer validates all 252 observations, matching datasets, complete operations, and stable sizes within each variant.

## CPU comparisons

Each value is the median paired CPU ratio: prototype divided by control.
A value below 1 uses less CPU.
Selected reads fetch the first, middle, and last rows.

| Rows | Store | Control | Insert | Full read | Selected read | Update | Compact |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 58 | File | O1 | 1.302 | 1.038 | 0.618 | 0.966 | 1.043 |
| 58 | Memory | O1 | 1.230 | 1.087 | 0.536 | 0.977 | 1.078 |
| 1,000 | File | O1 | 1.421 | 1.061 | 0.086 | 0.934 | 1.043 |
| 1,000 | Memory | O1 | 1.437 | 1.064 | 0.060 | 0.925 | 1.049 |
| 10,000 | File | O1 | 1.491 | 1.097 | 0.099 | 0.894 | 1.086 |
| 10,000 | Memory | O1 | 1.477 | 1.123 | 0.075 | 0.889 | 1.063 |
| 58 | File | Core JSON | 3.359 | 4.456 | 5.672 | 4.337 | 1.490 |
| 58 | Memory | Core JSON | 4.830 | 4.465 | 5.208 | 7.072 | 1.376 |
| 1,000 | File | Core JSON | 21.024 | 6.345 | 1.895 | 17.470 | 1.403 |
| 1,000 | Memory | Core JSON | 32.549 | 6.555 | 1.440 | 22.085 | 1.377 |
| 10,000 | File | Core JSON | 45.149 | 7.263 | 0.264 | 2.920 | 1.168 |
| 10,000 | Memory | Core JSON | 55.425 | 7.733 | 0.217 | 2.832 | 1.258 |

At 10,000 rows, median selected-read CPU falls from 6.93 to 0.68 ms on files and 6.68 to 0.50 ms in memory.
Those selected reads also beat Core JSON by about 3.8 to 4.6 times.
Updates improve modestly, but remain slower than Core JSON.
Insert allocations rise by 35% to 53%; full-read allocations rise by 35% to 64% against O1.
Selected-read allocations fall by 27% to 90%.

## Stored bytes

File and memory stores produce identical sizes.
Update bytes measure appended growth; initial and compacted sizes include database overhead.

| Rows | O1 initial | Prototype initial | O1 update | Prototype update | O1 compacted | Prototype compacted |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 58 | 3,217 | 4,216 | 2,973 | 3,971 | 3,218 | 4,216 |
| 1,000 | 45,098 | 59,284 | 44,854 | 59,039 | 45,099 | 59,284 |
| 10,000 | 455,217 | 597,077 | 47,058 | 61,579 | 455,218 | 597,077 |

Initial storage grows by about 31%.
Fixed-width integers, String offset tables, and presence bytes plausibly explain that growth.
Extra capture arrays and per-cell validation plausibly explain the allocation and full-read costs.
These are implementation-based inferences; no separate allocation profile was collected.

## Verification

Nine prototype tests pass with 71 assertions.
Coverage includes row boundaries, exact NaN bits, signed zero, encodings, key order, ownership, numeric updates, malformed offsets, and deferred corruption.
Regressions first failed for whole-column validation copies and excessive raw String capture, then passed after their fixes.

Independent QA exercised public flows at all three sizes, fallback, codecs, cycle rejection, snapshots, and rollback.
It checked twelve malformed variants, twenty chained actions, and selective cell traversal.
Follow-up QA checked the capture budget and bounds-only validation changes.
All runtime handles closed, input hooks remained unused, and source hashes remained stable during each QA run.
The production library retains its successful full gate: 540 tests, 42,601 assertions, 100% typed calls, and CRAP threshold 10.
Final independent source review found no Critical, Important, or Minor issues in the experiment or its measurement evidence.

## Reproduce and evidence

Extract `harness.json.gz` with the Ruby extraction script from the [O1 reproduction instructions](../ruby-input-capture/README.md#reproduce).
Use a checkout of `6d26b1d` for both production path arguments:

```sh
ruby /tmp/harness/prototype_test.rb
bundle exec ruby /tmp/harness/input_benchmark.rb /path/to/production /path/to/production /tmp/layout-samples.json
bundle exec ruby /tmp/harness/summarize_input.rb /tmp/layout-samples.json /tmp/layout-summary.json
```

In raw results, `ruby` identifies the prototype and `baseline` identifies O1.
The driver sets `XITDB_LAYOUT=1` only for prototype workers.
The archived sources use Ruby and the standard library; tests use the project's installed Minitest.

`samples.json.gz` retains observations, runtime details, source hashes, and correctness results.
`summary.json.gz` retains CPU, elapsed time, allocations, ranges, paired ratios, win counts, and bytes.
`harness.json.gz` contains seven exact source files, including the codec, adapter, and tests.
`qa.json.gz` retains independent reports, raw observations, source manifests, and test output.
It also retains the production quality-gate log and independent input QA reports.
`provenance.json` records archive checksums and the production control commit.
Source hashes, archive checksums, and a regenerated summary were verified before committing.

## Decision and limits

Keep the verified O1 change. Archive XP02 as an experiment.
Pursue direct row offsets separately before adopting column storage: the measured gain comes with unacceptable costs for other operations.
That next experiment is a recommendation, not an implemented feature.
The original all-case parity target remains unmet.

This experiment covers one host and one generated dataset.
It establishes no result for numeric-heavy datasets, other platforms, concurrency, or exhaustive corrupt-input fuzzing.
Global built-in monkeypatches and concurrent caller mutation remain outside the per-object input contract.
Control arguments such as a decorated `copy_from(at:)` Array retain their prior contract.
Application values retain strict validation and require explicit codecs.
