# G1-G5 completion evidence

The measured implementation is commit `a94e160`.
Its library, signature, and production test sources remain unchanged through commit `af154ea`.
Later cleanup is excluded from the timing evidence.
The control implementation is `6d26b1d`.
The [design](../../superpowers/specs/2026-11-13-ruby-storage-design.md) preserves the supplied goal and declares acceptance limits before candidate timing.

| Requirement | Authoritative evidence | Result |
| --- | --- | --- |
| G1: Supported values and behavior | `docs/ruby.md`, version 4 wire contract, production tests, integrated QA Q1-Q8 | Exact supported types, key identity, order, codecs, snapshots, rollback, selectors, and view ownership retained |
| G2: Compact rows with direct offsets | Indexed encoder/decoder, selection harness, public regressions, independent boundary probes | Compact cells, 16-bit row directory, integrity checks, and sequential/general fallback implemented |
| G2: Compare O1 and archived columns | Selection and production observations, exact worker and library hashes | Four variants measured without changing control sources |
| G3: Sizes, stores, datasets | Both complete runs contain 1,344 observations across 96 variant groups | Four datasets, three sizes, two stores, four variants, twelve measured observations and two warmups each |
| G3: Operations and metrics | Worker correctness lists, summaries, raw observations | Insert, full/selected read, update, compact; CPU, elapsed time, allocations, and three byte measures retained |
| G3: Application provenance | Fixture archive, source checksum, strict extractor, deterministic generators and contracts | 58 captured records; larger replays and synthetic variants identified explicitly |
| G4: Limits before selection | Contract commit `40546af`, clarification `4fd3497`, selection acceptance | All 444 prototype criteria pass without relaxing limits |
| G4: Integrated production decision | Original 442-check result, confirmation protocol `19abed4`, confirmation observations, pooled 444-check result | Every original observation retained; all operations pooled for the failed group; unchanged limits pass |
| G5: Correctness and corruption | Full gate, integrated QA, unit tests, independent source review | Exact values, malformed bounds, checksum failures, rechecksummed cells, fallback, and rollback verified |
| G5: Resource bounds | Raw resource report and scripts, capture/traversal tests | Bounded attempts and selected cell traversal verified; scoped child RSS measurements retained |
| G5: Repository gates | Final quality-gate log in production evidence | 548 tests, 42,826 assertions, zero failures/errors/skips, 100% typed calls across 82 files, CRAP <= 10 |
| G5: Independent review | Storage review and evidence review, archived reports | No storage issue; confirmation arithmetic and retained identities independently checked |
| G5: Portable archive verification | `reproduce.rb`, portable analysis contracts, guard checks | Both summaries and decisions regenerate, including original failures and final pooled pass |
| G5: Compatibility | Version 4 wire contract, header rejection tests and integrated QA | rb01/rb02/rb03 reject unchanged; rb04 reserved; no automatic migration claimed |

## Confirmation integrity

The original production matrix fails CPU and elapsed limits for application insertion at 1,000 rows in memory.
The confirmation protocol was committed before collecting the additional observations.
The unchanged worker contributes twelve additional measured observations per native implementation, plus two excluded warmups each.
All 24 measured native observations per implementation remain included in that group across all five operations.
Worker, library, input hash, correctness coverage, and byte-size invariants match.
No observation was discarded and no acceptance threshold was changed.
Original Core JSON and column comparisons retain their paired cohort.

The original failure and final pass are separate archived results.
The evidence does not establish a cause for the first discrepancy.

## Review finding and verification

The evidence review identified a portability gap in the new analysis tests.
The executor treated it as required G5 work because archive contracts must survive scratch cleanup.
With old scratch reads denied, the original tests fail with five missing-input errors.
The corrected tests use adjacent archived inputs and relative code paths, passing five tests and fifteen assertions.
They also pass from a copied archive directory.
After removal of the original scratch checkout, inputs, and temporary scripts, the complete archive replay passes again.

Additional guard probes reject corrupted archives and mismatched checkout sources before replay.
A deliberately altered acceptance result is rejected after regeneration even when its archive checksum is updated.
These probes supplement the unchanged-source, complete-sample, nonnegative-metric, and unfavorable-observation retention tests.

## Decisions and limits

The engineering acceptance limits are documented decisions, not latency budgets supplied by the user.
Actual applications may require stricter limits than these measured medians.
The format preserves all supported types through fallback and retains substantial general nested-storage costs.
The checksum is unauthenticated; deliberately rechecksummed unaccessed cells can require full decoding for canonical validation.
Global built-in monkeypatches and concurrent caller mutation remain outside the input contract.
One host, scaled fixtures, bounded resource probes, and finite corruption tests establish neither universal optimality nor exhaustive guarantees.
Historical changes before the review base were not re-audited.

All work is local. No push, merge, release, dependency addition, or compiled codec is part of this delivery.
