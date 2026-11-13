# Final Ruby storage design and acceptance rules

## Intent and authority

Finalize the Ruby profile storage implementation through G1 through G5 from the user-provided goal.
The source goal is the attached `pasted-text-1.txt`, supplied on November 13, 2026.
The user authorized prototyping, measurement, implementation, verification, documentation, and local commits.
No push, merge, release, new dependency, or custom compiled codec is authorized.
Continue in the established `perf/native-page-experiments` checkout.

## G1: Value and behavior contract

Retain all supported exact built-in classes: nil, booleans, Integer, Float, String, Symbol, Hash, Array, Set, Time, Date, DateTime, BigDecimal, and Rational.
Retain arbitrary-size Integers, exact Float bits, String bytes and encodings, temporal precision, and numeric scalar semantics from `docs/ruby.md`.
Ordinary keys remain exact nil, booleans, Integer, Float, String, or Symbol values with the documented canonical identities.
Retain original key representations, insertion order, sorted collection contracts, and explicit custom value codecs.
Never deserialize arbitrary Ruby classes or executable behavior.

Exact Array, Hash, and String input contents ignore per-object overrides through bound built-ins.
Retain strict validation for extended scalars, application values, subclasses, views, and codec configuration.
Reject cycles, unsupported defaults, identity comparison, and unregistered subclasses without calling their input hooks.
Retain callback mutation behavior, independent mutable materialization, snapshots, assignment rollback, transaction rollback, and view lifetimes.
Keep caches operation-local. Preserve the portable profile and existing Core contracts.

The general representations remain available when pages cannot represent a value.
The optimization must not remove supported Ruby types to improve a benchmark.

## G2: Approaches and selected experiment

O1 at `6d26b1d` is the production control; the starting checkout is `45a96b9` with identical library sources.
The archived XP02 column prototype is a comparison control, not a production candidate without fresh evidence.
Its selected-read improvement comes with higher insert CPU, full-read CPU, allocations, and stored bytes on the prior fixture.

The user selected compact row storage with direct row offsets as the next experiment.
Retain XP01 scalar cell encodings and shared ordered schemas.
Add a fixed-width 16-bit offset for every row boundary, addressing the bounded row payload directly.
Preserve the 65,536-byte page, 1,024-row, and sixteen-field limits.
Prototype a page checksum using the existing standard-library Digest implementation.
It detects accidental changes anywhere in a page without Ruby-level traversal of every cell.
Selected reads validate their row framing and cells; full reads validate every row and cell.
Malformed unselected cells with a recomputed valid checksum may be deferred until access or full read.
This limitation must appear in the wire contract and tests.

Full-column storage and unchanged XP01 are the other measured alternatives.
The compact format must win under the limits below before integration.
If no format passes, revise the candidate and keep the limits; do not silently lower the acceptance rules.

## G3: Data and measurement

Measure 58, 1,000, and 10,000 rows on both file and memory stores for each dataset.
Use the actual record schema and captured values from the neighboring crap4ruby `.metrics/crap.edn` snapshot.
Parse only that writer's bounded record grammar with standard-library code; do not add a general EDN parser dependency.
Archive the extracted fixture, source checksum, extraction source, and derivation rules.
Larger datasets repeat captured records deterministically and remain scaled replays, not independent production traces.
Add nested application-shaped records and numeric-heavy flat records with deterministic values.
Retain the previous synthetic six-field fixture as a continuity comparison if it differs from the captured application schema.

Compare compact rows, O1, archived columns, and direct Core JSON on identical JSON-compatible data.
Exact Ruby-only values belong in correctness tests; never coerce them into JSON to claim equivalent work.
Measure insert, full read, three selected rows, one numeric-field update, and compaction.
Verify snapshots, rollback, compaction results, and file reopening outside timings.
Record process CPU, elapsed time, allocations, and initial, update, and compacted bytes.
Use fresh processes, excluded warmups, balanced execution positions and predecessor order, and twelve measured observations per group.
Keep runtime verification and other project measurements stopped during timing.
Archive raw observations, source hashes, exact harness, aggregate medians, ranges, paired ratios, and correctness evidence.

## G4: Acceptance limits declared before candidate measurements

These limits are engineering decisions for this goal, not performance preferences explicitly supplied by the user.
Evaluate the candidate against simultaneously measured O1 observations on the same host and datasets.

- Median CPU for each operation and group must be at most O1 plus the larger of 10% or 0.2 ms.
- Selected-read median CPU must be at most one third of O1 at 1,000 and 10,000 rows on page-compatible flat datasets.
- Median elapsed time must be at most O1 plus the larger of 20% or 1 ms.
- Median allocations must be at most O1 plus the larger of 10% or 64 objects per operation.
- Each stored-byte measure must be within the larger of 6% or `3 * rows + 128 * pages` additional bytes over O1.

The absolute storage allowance accounts for mandatory row offsets and page integrity metadata on compact numeric records.
Nested fallback has no selected-read speedup requirement, but retains every regression limit.
Core JSON is a comparison, not an automatic parity gate for different database access capabilities.
Investigate noisy or contradictory groups with a fresh balanced confirmation run before selecting a winner.
Do not mix observations from different source versions or rewrite initial rules after seeing results.

## G5: Integration, compatibility, and proof

Integrate only the candidate selected under G4, including required signatures and focused public regressions.
If the wire format changes, use a distinct Ruby profile identifier, provisionally `rb04`.
Retain the pre-1.0 policy of rejecting incompatible older profile files without modifying them.
Document that policy explicitly; do not claim an implemented migration or backward reader.
Keep historical wire contracts and archived benchmark controls intact.

Test exact values, encodings, canonical keys, ownership, hostile hooks, codecs, fallback, deep input, cycles, snapshots, rollback, and view expiry.
Test dimensions, canonical scalar framing, every row boundary, offsets, checksum failures, truncation, trailing bytes, and deliberately rechecksummed malformed rows.
Verify limits before excessive capture, bounded selected-row work, and operation-local cache lifetimes.
Run `bundle exec rake`: style, RBS, Steep, 100% typed calls, coverage tests, and CRAP threshold 10.
Run independent public API QA, then final independent source review. Fix important findings with failing regressions.
Measure the final integrated production implementation under G3 and G4; scratch results alone cannot establish completion.
Commit code and reproducible evidence locally. Leave the checkout clean and preserve the branch.

## Explicit limits

Global built-in monkeypatches and concurrent caller mutation remain outside the input contract.
One-host timing does not establish cross-platform performance.
Peak-memory evidence must state its fixture, process boundary, and measured scope.
Finalization selects and documents a format; it does not establish universal optimality or freeze all future internal changes.
