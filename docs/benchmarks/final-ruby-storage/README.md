# Final Ruby storage format

The `rb04` implementation retains compact scalar cells and adds direct row offsets and whole-page integrity.
Its prototype passed all 444 acceptance checks across 1,344 observations.
The integrated comparison initially passed 442 checks; a balanced confirmation pooled with every original observation passes all 444 unchanged limits.
The original failures and confirmation remain in the archives.

## Contract and limits

The [design contract](../../superpowers/specs/2026-11-13-ruby-storage-design.md) defines G1 through G5 and the acceptance rules before measurement.
The implementation preserves supported Ruby values, exact scalar representations, key identity, ordering, codecs, snapshots, rollback, and view ownership.
Portable behavior is unchanged.
The [version 4 wire contract](../../ruby-profile-v4.md) defines the selected representation and compatibility policy.

Every operation and group must meet the CPU, elapsed-time, allocation, and stored-byte limits against O1.
Page-compatible flat datasets must also improve selected-read CPU by at least three times at 1,000 and 10,000 rows.
The checker evaluates every group separately; passing groups cannot hide a regression elsewhere.
Core JSON is a comparison control, not a parity gate.

## Fixtures

`fixture.json.gz` contains 58 captured crap4ruby metric records, source provenance, the strict extractor, deterministic generators, and fixture tests.
The source snapshot is `crap4ruby/.metrics/crap.edn`; its checksum appears in `fixture-provenance.json` and the captured metadata.
The fixture tests verify source types, independent values, JSON equivalence, and deterministic dataset hashes at each measured size.

The four datasets are:

- Application: captured names, namespaces, complexity, coverage, and CRAP scores, repeated deterministically for larger sizes.
- Nested: captured application fields plus deterministic nested maps and arrays.
- Numeric: six numeric or nullable fields derived from captured values and row indices.
- Continuity: the prior synthetic six-field dataset with three Strings, an Integer, and two nil values.

The larger application datasets are scaled replays, not independent production traces.
The nested and numeric structures are synthetic variants, not observed production distributions.
All comparison fixtures are JSON-compatible; separate correctness tests cover exact Ruby-only values.

## Selection method

The run compares the compact-row prototype, O1 at `6d26b1d`, the archived column prototype, and direct Core JSON.
Each dataset runs at 58, 1,000, and 10,000 rows on file and memory stores.
Each group has two excluded warmups and twelve measured observations per variant.
Four Williams orders balance execution positions and direct predecessors across measured samples.
Each observation runs in a fresh process; startup, fixture generation, and explicit GC are excluded from operation timings.
No other project runtime verification or benchmark ran during timing.

Workers measure insert, full read, three selected rows, one numeric-field update, and compaction.
They record CPU, elapsed time, allocations, initial bytes, appended update bytes, and compacted bytes.
Outside timing, workers verify values, old snapshots, deliberate transaction rollback, compacted results, and file reopening where applicable.
The driver verifies Ruby-only codec sources and unchanged library, harness, fixture, and design hashes.
The summarizer checks all 96 variant groups, sample indices, warmups, matching datasets, execution balance, operations, and stable sizes.
The acceptance checker requires all 444 individual criteria; its own tests cover complete passing data, one failing criterion, and missing groups.

## Selection findings

At 1,000 and 10,000 rows, paired median selected-read CPU improves by about 8 to 14 times across the flat datasets.
Their updates use about 24% to 31% less CPU than O1.
Full reads use about 4% to 9% more CPU, while insert changes remain within the declared limits.
Initial stored size grows about 4% for application records, 4.5% for continuity records, and 6.3% to 6.5% for numeric records.
The numeric increase fits the predeclared absolute index allowance; no acceptance rule was changed after measurement.
Nested data retains general storage and approximately unchanged costs.

The selected layout improves direct access with less storage growth than the archived column design.
It keeps the sequential `XP01` page as a fallback when index overhead exceeds the byte budget.
It adds a checksum so ordinary corruption outside a selected row is detected without decoding every unrelated cell.
Deliberately rechecksummed malformed unaccessed cells remain deferred until access or full decoding.

The remaining costs are material.
For 10,000 nested file records, prototype median CPU is 2.11 seconds for insertion, 1.75 seconds for full reading, and 7.92 seconds for compaction.
Core JSON uses approximately 4.44 ms, 12.12 ms, and 2.06 ms for those operations in the same selection run.
The native representation remains expensive for bulk nested traversal and compaction; the selected row-page change does not solve those general-storage costs.
The original universal Core JSON parity target remains unmet.

## Integrated production confirmation

The fresh production matrix repeats all four datasets, sizes, stores, and controls against implementation commit `a94e160`.
Its 1,344 observations pass source-stability checks and all but two acceptance criteria.
Both failures concern insertion of 1,000 application records in memory: CPU and elapsed time.
The [confirmation procedure](confirmation-protocol.md) was committed after observing that problem, before collecting confirmation data.
It applies the design's predeclared noise policy without changing any limit.

Twelve additional measured observations per native variant, plus excluded warmups, use the unchanged worker and alternating order.
Worker, library, fixture, correctness, and stored-size checks match the original run.
Every original and confirmation native observation is pooled for that group, across all five operations.
The confirmed native groups contain 24 measured samples each; other groups retain twelve.
Core JSON and column comparisons retain their original paired observations.

| Insert CPU median | rb04 | O1 |
| --- | ---: | ---: |
| Original matrix | 11.1685 ms | 8.7695 ms |
| Confirmation | 7.7970 ms | 7.6510 ms |
| All native observations pooled | 8.5610 ms | 8.5000 ms |

The pooled summary passes all 444 unchanged checks, including elapsed time and all other operations.
This repeat shows variability; it does not establish that the original discrepancy was harmless noise.
No unfavorable observation was discarded.
Acceptance compares absolute per-group medians; paired ratios and their ranges remain separately recorded.

In the integrated results, larger flat selected reads use about 8 to 14 times less CPU than O1.
Their updates use about 21% to 32% less CPU, with additional index and integrity storage as recorded above.
Nested bulk costs remain substantial: 10,000 file records use 2.18 seconds for insertion, 1.82 seconds for full reading, and 8.23 seconds for compaction.
The corresponding Core JSON measurements are approximately 4.65 ms, 12.26 ms, and 2.13 ms.

## Correctness and resources

The full production quality gate passes 548 tests and 42,826 assertions, with 100% typed calls across 82 library files and CRAP at most 10.
Independent integrated QA covers compatibility, exact values, codecs, callbacks, sorted collections, selectors, rollback, corruption, and bounded row traversal.
Independent source review found no storage integration issues.
Independent evidence review reproduced the original failure and pooled pass, checked retained samples, and confirmed unchanged acceptance limits.

Three fresh macOS workers per implementation measure maximum resident memory for a bounded page probe, including Ruby startup.
O1 uses 27.6 to 28.1 MB; rb04 uses 28.5 to 28.8 MB, using decimal megabytes.
Selected decoding visits six schema/row cells instead of O1's 3,075 cell visits in that probe.
Oversized input attempts remain within the stated four-page String capture allowance, including sequential fallback attempts.
Twenty repeated encode/selected-read cycles retain two versus three additional live heap slots after GC.
These are scoped observations, not an application-wide peak-memory bound or proof of universal leak freedom.

The checksum provides integrity, not authentication.
Deliberately rechecksummed unselected cells require access or full decoding for canonical validation.
Global built-in monkeypatches and concurrent caller mutation remain outside the per-object input contract.

## Evidence and reproduction

`selection-run.json.gz` contains raw observations, runtime details, correctness coverage, and source hashes.
`selection-summary.json.gz` contains absolute medians, ranges, paired ratios, win counts, allocations, elapsed time, and bytes.
`selection-acceptance.json.gz` contains all 444 limits and decisions.
`selection-harness.json.gz` contains the exact measured sources and captured application data.
`selection-qa.json.gz` retains independent preliminary QA reports, observations, scenarios, and source manifests.
`selection-provenance.json` records archive checksums and the control commits.

`production-run.json.gz` retains the integrated full matrix.
`production-primary-summary.json.gz` and `production-primary-acceptance.json.gz` retain the original 442-check result.
`production-confirmation-run.json.gz` retains all 28 confirmation observations, including four warmups.
`production-summary.json.gz` and `production-acceptance.json.gz` retain pooled statistics and all 444 final decisions.
`production-harness.json.gz` contains the exact measured sources.
`production-evidence.json.gz` contains quality-gate, QA, source-review, resource, and confirmation-runner evidence.
`production-provenance.json` binds artifact checksums and production source hashes.

From the matching source checkout, verify both archives without repeating timings:

```sh
bundle exec ruby docs/benchmarks/final-ruby-storage/reproduce.rb
```

The verifier extracts sources into fresh temporary directories and reruns fixture, codec, and acceptance contracts.
It regenerates the selection decisions, original integrated failures, pooled summary, and final decisions from raw observations.
It also runs the portable confirmation regression tests in `analysis_test.rb`.
Those tests reject mixed implementations, missing samples, negative measurements, and confirmation of a passing group.
They verify retention of deliberately unfavorable original observations.

Extract the harness JSON object into a temporary directory, retaining relative names such as `column/adapter.rb`.
Export commit `6d26b1d` into a separate control directory.
Use a checkout containing the unchanged design contract for the production path argument.

```sh
ruby /tmp/harness/fixture_test.rb
ruby /tmp/harness/compact_test.rb
ruby /tmp/harness/acceptance_test.rb
bundle exec ruby /tmp/harness/benchmark.rb /path/to/checkout /path/to/o1 production /tmp/production.json
ruby /tmp/harness/summarize.rb /tmp/production.json /tmp/summary.json
ruby /tmp/harness/acceptance.rb /tmp/summary.json /tmp/acceptance.json
```

New timing observations can differ; archive replay regenerates recorded statistics rather than promising identical fresh timings.
The selected format retains all supported Ruby values through compact pages or general storage.
Older Ruby profile files reject without modification, as specified by the version 4 compatibility policy.
One host and these datasets do not establish universal performance or exhaustive corrupt-input safety.
