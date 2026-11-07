# Packed native representation experiments

The selected prototype combines bounded records, shared field dictionaries, bounded String sharing, and bottom-up array construction.
It retains Ruby scalar payloads and the existing trees for large collections.
The production implementation and final seven-sample comparison follow this selection.

## Evidence and limits

These experiments contain 90 serial, single-sample probes across the fixture, 1,000 records, and 10,000 records.
Each dataset uses memory and file stores, including reopened file handles.
Portable native records and complete JSON workflows provide controls.
JSON timings include encoding and decoding.

The fixture contains 58 records and 7,696 JSON bytes.
Its JSON SHA-256 is `d975d573ec71a8b2ae214d47f1092d0ecf658c1243861449f437c30e74f3d081`.
Raw reports include input file hashes, exact Ruby input digests, library hashes, allocations, byte traffic, and correctness checks.

Probes have no warmups or repeated latency samples. Measurements from separate stages are not paired estimates.
They establish representation costs and guide implementation. The final comparison must establish latency ratios with alternating pairs.
The original baseline measurements remain historical, with their actual sample counts recorded in [the rb01 history](rb01-history.md).

## Representation comparison

This table shows individual file-store probes for 10,000 deterministic records.
The original row is historical; other rows come from the archived experiment stages.
Times are seconds, and sizes are bytes.

| Representation | Initial size | Compacted size | Insert | Full read | Reassign |
|---|---:|---:|---:|---:|---:|
| Original rb01, historical one sample | 116,459,112 | 26,821,960 | 162.393 | 24.080 | 216.266 |
| Optimized rb01 | 52,457,512 | 26,821,960 | 58.557 | 18.647 | 56.945 |
| Portable native | 18,502,088 | 4,666,590 | 25.671 | 1.333 | 26.892 |
| Portable JSON | 1,160,301 | 1,160,053 | 0.00414 | 0.00506 | 0.00342 |
| Packed maps, incremental arrays | 8,905,988 | 3,710,785 | 27.577 | 6.171 | 27.500 |
| Packed maps, bottom-up arrays | 3,710,740 | 3,710,785 | 26.349 | 6.058 | 26.528 |
| Shared field-name payloads | 2,180,893 | 2,180,938 | 21.427 | 6.027 | 21.573 |
| Shared field dictionaries | 1,730,955 | 1,731,000 | 21.734 | 0.820 | 21.917 |
| Selected prototype | 1,106,782 | 1,106,827 | 3.795 | 0.844 | 3.763 |

The selected prototype also completes three indexed reads in 3.13 ms and one nested update in 3.95 ms.
Those operations read 11,079 and 7,569 logical bytes respectively. The nested update grows the file by 891 bytes.
An identical reassignment grows the file by 1,106,537 bytes. Thirteen retained commits occupy 2,216,527 bytes.
Compaction takes 3.28 seconds in this probe.

The selected insert allocates 6,352,716 objects. Its full read allocates 2,148,292 objects.
The optimized rb01 probe allocates 203,218,775 and 34,099,424 objects respectively.
Store API traffic includes repeated reads and overwritten bytes. Compaction traffic also includes temporary offset-map storage.

## Byte accounting

The following ledger accounts for every byte in the selected compacted 10,000-record file after updates and revision commits.

| Retained component | Bytes |
|---|---:|
| 10,000 row records, 71 bytes each | 710,000 |
| Array blocks and header | 96,352 |
| Array wrapper | 17 |
| Shared six-field dictionary | 62 |
| String payloads, including original keys | 299,945 |
| Root map | 44 |
| File initialization, history, and commit overhead | 407 |
| Total | 1,106,827 |

The String total comprises 298,890 bytes for method names, 852 for shared namespaces and paths, and 203 for keys.
The 407-byte overhead includes a 37-byte header, two 25-byte trailers, and two 160-byte history records.
One empty history record and the initialization trailer are unreachable, a fixed 185-byte remainder after compaction.

An rb01 six-field map uses seven 160-byte array records for its envelope and entries, before indexes or scalar payloads.
Of those 1,120 structural bytes, 810 are unused leaf slots.
A literal packed map needs 116 bytes. A dictionary map needs 71 bytes, plus one shared 62-byte dictionary.
This directly removes retained representation overhead.
Bottom-up array construction separately removes intermediate writes; it leaves compacted array size unchanged.

## Execution costs

The 1,000-record packed-map profile spends 2.048 of 2.262 instrumented CPU seconds in 32,014 input guard calls.
Repeated method-table inspection also accounts for 1.91 million allocations.
These inclusive measurements overlap other method costs, and instrumentation changes timing.

The selected profile reduces those calls to 7,017 and their CPU cost to 0.291 seconds.
Total instrumented insert CPU falls to 0.409 seconds, with 831,171 allocations.
Validated scalar encoding avoids duplicate guards. Exact immediate values require no per-object singleton inspection.
Frozen key identities can be reused safely by object identity within one encoding operation.
Mutable inputs still require validation each time.

An Enumerator runs input validation in a separate fiber. A fiber-local cache alone fails to cover that execution path.
The prototype propagates its scope into the Enumerator. Production will pass explicit operation state.
Stored keys come from built-in decoders without application codecs; their canonical encoding requires no application-object inspection.

## Selected design and trade-offs

Small maps, sets, and arrays use records with an eight-byte header followed by at most 32 nine-byte slots.
Maps preserve original key slots and insertion order directly. Their bounded scans replace separate lookup and order indexes.
Larger maps keep the existing indexed representation. Larger arrays use sixteen-slot tree blocks and bounded construction buffers.
Oversized values remain separate byte records. Updates copy the affected record and ancestor path.

Field dictionaries and scalar sharing are bounded per encoding operation. They preserve scalar type, exact bytes, and String encoding.
Only short built-in names and Strings qualify. Application codecs retain their normal execution behavior.
Read dictionaries are cached only within one read-only materialization operation.
Concurrent calls receive separate state; transaction materialization avoids reusable offset caches.

Inline typed cells and 1, 4, or 16 KiB chunks were considered as design alternatives, without working implementations.
They could remove scalar headers and reduce parser calls, but require relocation rules, another parser, and larger update copies.
The measured record design already removes most retained overhead and keeps an 891-byte nested update.
Its exact byte ledger leaves only 96,369 bytes in array storage and its wrapper, about 8.7% of the retained file.
A replacement array tree therefore has limited storage benefit for this workload.

The selected design intentionally uses `rb02` and a Core record extension. No rb01 reader or migration is required.
Portable records keep their wire format. Pinned upstream implementations cannot maintain files containing the native record extension.
Opaque scalar payload guarantees can be tested separately inside portable graphs.

Unchanged reassignment still encodes a complete graph. Large indexed maps retain their dual-index costs.
Full native reads remain much slower than JSON decoding. Input guards and Ruby scalar decoding remain measurable costs.
Compaction also spills its bounded offset map for the larger graph.
These limits remain targets for measurement, not reasons to claim JSON-level performance.

## Reproduction

Run a selected fixture probe with the archived library, fixture, and benchmark source:

```sh
bundle exec ruby script/native_packing_replay.rb --variant selected --count fixture --store file --output pkg/replay-selected-fixture.json
```

Choose `1000` or `10000` with `--count`, and `memory` or `file` with `--store`.
Variants include `optimized`, `indexed`, `builder`, `shared`, `schema`, `checked`, `values`, `frozen`, and `selected`.
Use `--variant optimized --layout portable` or `--layout json` for controls.
Output paths must be absent. Replay verifies the source archive digest before extracting temporary copies.

Compressed samples, profiles, source libraries, QA scripts, logs, and the exact fixture are recorded in `packing-provenance.json`.
The replay source replaces archived absolute paths with its temporary directory; its reported source hashes reflect those rewritten paths.
Prototype checks cover numeric bits, encodings, key equality, order, snapshots, rollback, concurrency, deep values, and oversized adjacency.
Delete, clear, and other incomplete prototype operations require production regression tests before use.
