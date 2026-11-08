# Native input validation

Commit `efc2638` bypasses method-list reflection for Object descendants without singleton classes. Other inputs retain the original validation.

The guard uses Ruby's `rb_obj_is_kind_of`, `CLASS_OF`, and `rb_obj_class` APIs without dispatching application callbacks or creating singleton classes.

The [Ruby C API documentation](https://docs.ruby-lang.org/capi/en/master/d8/d36/group__object.html) describes these class and ancestry queries. Both function declarations also exist in Ruby's `v3_3_0` headers.

## Cause and evidence

An instrumented 1,000-row update invokes the input guard 27 times. Those checks consume 1.63 ms of its 3.26 ms CPU cost.

With the native check, guard cost falls to 0.02 ms and total cost to 1.58 ms. These instrumented observations identify the cause, not acceptance performance.

The balanced comparison uses the [production workload](../native-production/README.md), with two excluded warmups and twelve measured observations per variant, size, and store.

It switches between the exact original guard from `9e1ebd1`, the production candidate, and direct Core JSON within one process.

All six execution orders repeat twice. Input, storage code, native codec, correctness checks, and garbage-collection policy remain identical between guard variants.

## Results

Ratios compare candidate CPU time with the original guard. Values below one favor the candidate.

| Rows | Store | Insert ratio | Update ratio | Update CPU ms, original | Update CPU ms, candidate |
| ---: | --- | ---: | ---: | ---: | ---: |
| 58 | File | 0.650 | 0.542 | 3.678 | 1.955 |
| 58 | Memory | 0.552 | 0.412 | 2.783 | 1.151 |
| 1,000 | File | 0.712 | 0.576 | 4.046 | 2.350 |
| 1,000 | Memory | 0.637 | 0.469 | 3.213 | 1.535 |
| 10,000 | File | 0.891 | 0.594 | 4.119 | 2.457 |
| 10,000 | Memory | 0.874 | 0.484 | 3.259 | 1.578 |

Ratios are paired medians; absolute times are independent medians. Inserts and updates improve in every paired observation across all six cases.

Selected-read paired CPU ratios range from 0.789 to 0.876. Compaction does not show a consistent improvement; its memory ratio at 10,000 rows is 1.017.

Storage sizes remain unchanged. At 10,000 rows, each update appends 47,419 bytes and compaction produces 455,218 bytes.

Core JSON parity remains unmet. Candidate insert medians at 10,000 rows are 2.601 ms for files and 2.175 ms for memory; Core requires 2.055 and 1.699 ms.

Candidate update medians at that size beat Core's 4.722 and 4.282 ms. Small operations still lose: 58-row file updates require 1.955 versus 0.347 ms.

## Verification and limits

The full gate passes 521 tests and 42,486 assertions, style checks, RBS, Steep, 100% typed calls, and the complexity threshold.

Independent QA matches 155 paired observations across native, portable-only, chilled, and frozen inputs. It covers live mutation, codecs, rollback, and reopening.

Source review reports no defect. Runtime verification remains limited to Ruby 4.0.9 on Darwin arm64; Ruby 3.3 header compatibility does not prove runtime behavior there.

The timing matrix ran after tests and runtime QA stopped. Scheduling and filesystem caches remain uncontrolled.

## Replay

`provenance.json` records the candidate commit, original guard commit, runtime, source hashes, binary hash, and artifact hashes.

Extract the `files` mapping from `harness.json.gz` using the procedure in the production benchmark.

1. Build the recorded candidate checkout with `bundle exec rake compile`.
2. Run `ruby /scratch/guard_benchmark.rb /checkout /scratch/samples.json`.
3. Run `ruby /scratch/guard_summary.rb /scratch/samples.json /scratch/summary.json`.

Output files must not exist. The baseline loader omits its redundant require and constant declaration, then restores the captured candidate method between variants.

The raw samples retain all measured and warmup observations. The summary retains operation medians, ranges, allocation counts, sizes, and paired candidate/Core ratios.
