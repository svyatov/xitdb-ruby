# Native Ruby storage performance

The packed native profile uses `rb02`. Small maps, sets, and arrays have bounded records with ordered slots. Large arrays retain an indexed tree built from completed blocks. Field dictionaries and short scalar values share storage within bounded encoding operations.

For 10,000 records in a file, median insert falls from 59.75 to 3.72 seconds and full read from 18.50 to 0.790 seconds against optimized rb01. Compacted storage falls from 26,821,960 to 1,106,827 bytes, a 95.9% reduction. All six native dataset/store cases improve substantially in both bulk operations and retained storage.

This intentionally replaces `rb01`. Existing rb01 native files cannot be opened by this profile. No migration or backward reader is included. Portable files retain their wire format.

## Workload and method

The source fixture is the separate, unchanged crap4ruby checkout. Sorted `lib/**/*.rb` files are analyzed with `Crap4Ruby::Analyzer.new.call(File.binread(path), path: path)`. Each method produces the six ordered fields specified in the task: name, namespace, path, complexity, coverage, and crap.

The fixture contains 58 records. Its JSON representation is 7,696 bytes, with SHA-256 `d975d573ec71a8b2ae214d47f1092d0ecf658c1243861449f437c30e74f3d081`. The digest of `Marshal.dump(records)` is `788ae8b9c6339262b24d51d020b97f9cfac67e5e5e73f36330348635a836321e`. Workers receive an owned Marshal fixture file to preserve String encodings. Raw artifacts contain the fixture revision and every input file hash.

Deterministic 1,000- and 10,000-record datasets use six fields, unique method names, seventeen namespaces, eleven paths, twenty complexity values, and two nil fields. They measure repeated record shapes and short repeated values. Results do not establish equivalent gains for unrelated shapes, large maps, or long unique values.

Each comparison has eighteen cases: three datasets, memory and file stores, and native, portable, and portable JSON layouts. Every case has one excluded warmup pair and seven measured pairs. Revision order alternates within each case. Workers run serially in fresh processes, with library loading measured separately. Both library revisions are extracted from Git before measurement.

The read operation materializes the complete result and checks equality. An untimed correctness read precedes the timed read on the original handle. Native reads also check key order and String encodings. Indexed operations read rows at the start, middle, and end. Reopened indexed reads precede full reads on the reopened handle. These are warm OS-cache measurements, not cold-disk tests. JSON operations include encoding for writes and decoding for reads and updates.

An identical reassignment is a second complete assignment in a transaction. A nested update changes the middle row's complexity. Ten further commits change a root revision field. Earlier snapshots must remain equal to the original input. Compaction retains the latest history, which must still match the updated input. File stores are also reopened after all writes.

Timing uses a monotonic clock. Allocation counts use `GC.stat(:total_allocated_objects)`, with a full collection before each timed operation. OS caches are not flushed. Elapsed times include normal transaction flush behavior; they do not imply a new durability setting. Instrumented CPU and byte-traffic probes run separately from the timing matrix.

The matrix uses Ruby 4.0.9, revision `3e93b23afc`, with PRISM on `arm64-darwin25`. The checkout continues to report gem version 0.1.0. CPU-model and physical-RAM queries through `sysctl` were denied by the sandbox, so those hardware details are unavailable.

The fresh comparison uses optimized rb01 revision `fde9a5dda601643398289f5bd0ebfdbfa7f2089e` and packed revision `af53aeb834e396eddfd2e077798d0ec614eb066f`. Original baseline revision `89f714d8de855cb9fdd31eb3f9e5e8d666cd8bef` is measured in the separately archived historical comparison. Its interrupted run was preserved before packing experiments; missing samples are resumed with its exact archived worker and matching library hashes. Historical and fresh timings must not be treated as one simultaneous paired run.

## Results

The following fresh native comparisons have seven measured samples per revision and an excluded warmup pair. Cells show optimized rb01 / packed rb02, followed by the ratio of unrounded medians. Bulk-operation times are seconds.

| Records | Store | Insert | Full read | Reassign | Compact |
|---:|---|---:|---:|---:|---:|
| 58 | memory | 0.213 / 0.024 (8.9x) | 0.072 / 0.003 (21.8x) | 0.208 / 0.022 (9.4x) | 0.052 / 0.005 (10.1x) |
| 58 | file | 0.244 / 0.025 (9.9x) | 0.105 / 0.005 (22.4x) | 0.243 / 0.024 (10.1x) | 0.073 / 0.006 (11.7x) |
| 1,000 | memory | 3.884 / 0.359 (10.8x) | 1.221 / 0.054 (22.7x) | 3.900 / 0.356 (10.9x) | 7.040 / 0.058 (121.3x) |
| 1,000 | file | 4.694 / 0.369 (12.7x) | 1.778 / 0.075 (23.8x) | 4.567 / 0.370 (12.3x) | 7.316 / 0.084 (86.6x) |
| 10,000 | memory | 52.145 / 3.581 (14.6x) | 12.274 / 0.550 (22.3x) | 52.902 / 3.647 (14.5x) | 96.246 / 2.975 (32.3x) |
| 10,000 | file | 59.749 / 3.724 (16.0x) | 18.499 / 0.790 (23.4x) | 59.357 / 3.774 (15.7x) | 95.052 / 3.293 (28.9x) |

Selective-operation times below are milliseconds. Indexed reads select three complete rows.

| Records | Store | Three indexed reads | Nested update | Ten commits |
|---:|---|---:|---:|---:|
| 58 | memory | 7.664 / 2.176 (3.5x) | 4.691 / 2.192 (2.1x) | 13.540 / 6.696 (2.0x) |
| 58 | file | 10.823 / 3.009 (3.6x) | 7.810 / 3.274 (2.4x) | 21.751 / 10.489 (2.1x) |
| 1,000 | memory | 7.529 / 2.239 (3.4x) | 4.817 / 2.253 (2.1x) | 13.426 / 6.412 (2.1x) |
| 1,000 | file | 10.866 / 3.130 (3.5x) | 8.103 / 3.905 (2.1x) | 21.246 / 11.494 (1.8x) |
| 10,000 | memory | 7.860 / 2.375 (3.3x) | 5.134 / 2.450 (2.1x) | 14.418 / 6.657 (2.2x) |
| 10,000 | file | 11.403 / 3.313 (3.4x) | 8.443 / 4.135 (2.0x) | 21.996 / 11.271 (2.0x) |

Reopened-file times are milliseconds. Three indexed reads precede complete materialization on each reopened handle.

| Records | Open handle | Three indexed reads | Complete read |
|---:|---:|---:|---:|
| 58 | 0.444 / 0.396 (1.1x) | 10.631 / 3.038 (3.5x) | 105.233 / 4.682 (22.5x) |
| 1,000 | 0.454 / 0.409 (1.1x) | 10.692 / 3.098 (3.5x) | 1,781.104 / 74.539 (23.9x) |
| 10,000 | 0.565 / 0.438 (1.3x) | 11.580 / 3.234 (3.6x) | 18,320.113 / 789.021 (23.2x) |

For 10,000 file-backed records, insert allocations fall from 211,126,083 to 6,321,335, and full-read allocations fall from 34,099,421 to 1,968,278. The raw matrix retains allocations for every operation and sample.

The native byte counts below are identical in memory and file stores. The latest state includes the nested update and root revision field.

| Records | Original rb01 initial | Optimized rb01 initial | Packed initial | rb01 compacted | Packed compacted | Packed retained bytes/record |
|---:|---:|---:|---:|---:|---:|---:|
| 58 | 665,247 | 292,447 | 7,865 | 158,695 | 7,910 | 136.38 |
| 1,000 | 11,528,267 | 5,126,667 | 111,238 | 2,682,891 | 111,283 | 111.28 |
| 10,000 | 116,459,112 | 52,457,512 | 1,106,782 | 26,821,960 | 1,106,827 | 110.68 |

The following packed history growth is measured in bytes. All source histories contain thirteen commits; compacted files contain one.

| Records | Identical reassignment growth | Nested update growth | Ten commits growth | Total before compaction | After compaction |
|---:|---:|---:|---:|---:|---:|
| 58 | 7,620 | 603 | 2,317 | 18,405 | 7,910 |
| 1,000 | 110,993 | 747 | 2,317 | 225,295 | 111,283 |
| 10,000 | 1,106,537 | 891 | 2,317 | 2,216,527 | 1,106,827 |

The following controls use the packed revision's library and file stores, with seven measured samples each. Times are seconds. JSON encoding and decoding are included.

| Records | Layout | Initial bytes | Compacted bytes | Insert | Full read | Three indexed reads | Nested update |
|---:|---|---:|---:|---:|---:|---:|---:|
| 58 | Native | 7,865 | 7,910 | 0.024768 | 0.004683 | 0.003009 | 0.003274 |
| 58 | Portable | 94,551 | 29,293 | 0.106449 | 0.007514 | 0.002024 | 0.002470 |
| 58 | JSON | 8,581 | 8,333 | 0.001885 | 0.000283 | 0.000256 | 0.001182 |
| 1,000 | Native | 111,238 | 111,283 | 0.368520 | 0.074782 | 0.003130 | 0.003905 |
| 1,000 | Portable | 1,729,947 | 466,225 | 1.780262 | 0.130092 | 0.002162 | 0.003095 |
| 1,000 | JSON | 115,826 | 115,578 | 0.002020 | 0.000712 | 0.000480 | 0.001725 |
| 10,000 | Native | 1,106,782 | 1,106,827 | 3.723737 | 0.790282 | 0.003313 | 0.004135 |
| 10,000 | Portable | 18,502,088 | 4,666,590 | 18.598426 | 1.305861 | 0.002269 | 0.003332 |
| 10,000 | JSON | 1,160,301 | 1,160,053 | 0.003979 | 0.005184 | 0.002768 | 0.006296 |

At 10,000 records, native storage is 4.6% smaller than the compacted JSON control. JSON remains about 936 times faster for complete insert and 152 times faster for complete read. Even its complete-payload indexed read is faster here, 2.77 ms against native's 3.31 ms. Native's selective access avoids decoding the complete payload, but does not guarantee lower latency at these sizes. Its nested update is faster and writes a bounded path instead of replacing the complete payload.

Xitdb loading is excluded from operation timings. The harness has already loaded JSON and its other standard-library reporting tools before this measurement. The table below aggregates forty-two measured Xitdb requires per revision/layout. These are medians across datasets and stores, in milliseconds; they are not complete process-startup times.

| Layout | Optimized rb01 load | Packed revision load | Optimized allocations | Packed allocations |
|---|---:|---:|---:|---:|
| Native | 51.863 | 53.005 | 33,317 | 34,087 |
| Portable | 20.498 | 20.926 | 11,370 | 11,613 |
| JSON | 20.379 | 20.880 | 11,370 | 11,613 |

The fresh matrix contains 252 measured rows and thirty-six excluded warmups. The original-baseline matrix is also complete. It preserves its first 245 rows unchanged and adds 43 resumed rows with the original worker and verified library hashes. It has 252 measured rows and thirty-six excluded warmups. The 10,000-record native file case combines one earlier and six resumed original-baseline samples, and two earlier and five resumed optimized samples. These are historical/resumed results, separate from the fresh comparison above.

The table below gives original-baseline medians, in seconds, with seven measured samples per case. It shows why the earlier memory-store and construction changes must remain comparison points.

| Records | Store | Original insert | Original full read | Original reassign |
|---:|---|---:|---:|---:|
| 58 | memory | 0.325 | 0.086 | 0.404 |
| 58 | file | 0.422 | 0.135 | 0.417 |
| 1,000 | memory | 34.973 | 1.366 | 68.300 |
| 1,000 | file | 12.405 | 2.302 | 12.982 |
| 10,000 | memory | 2,277.276 | 13.995 | 3,069.151 |
| 10,000 | file | 165.205 | 22.453 | 202.403 |

For 10,000 records, the original history occupies 232,935,769 bytes after thirteen commits. Optimized rb01 occupies 104,923,609 bytes; packed rb02 occupies 2,216,527 bytes. An original nested update adds 3,617 bytes, compared with 891 packed bytes. The two rb01 implementations retain the same 26,821,960 bytes after compaction, while packing retains 1,106,827 bytes.

The archived [representation experiments](benchmarks/native-records/packing-design.md) contain the selection evidence and its single-sample limitations.

## Why the previous representation was expensive

An rb01 six-field map needs seven 160-byte array records for its envelope and entries before adding lookup indexes, insertion-order indexes, or scalar payloads. Of those 1,120 structural bytes, 810 are unused leaf slots. The initial encoding also writes intermediate container versions that compaction later removes.

The earlier optimized implementation removes many intermediate writes and repeated traversals. Its compacted size is unchanged. That result separates construction waste from retained representation overhead.

The archived instrumented 1,000-record memory profile measures 63,023 checkpoint calls in the original implementation, capturing 148,788,474 cursor slots. Checkpoints account for 17.63 of 35.17 measured CPU seconds and 149.27 million of 157.41 million allocations. Optimized rb01 reduces those figures to 23,013 calls, 4,511,207 captured slots, 0.666 CPU seconds, and 4.68 million checkpoint allocations. Inclusive method costs overlap; instrumentation changes timings.

A separate retained-tail control exposes the original memory-store amplification. It retains twenty 144-byte tail reads from a 1 MiB store, writing one byte after each read. Original String memory grows by 20,973,940 bytes because shared tail slices force complete-store copies on later writes. Copying only the requested bytes reduces that measured increase to 4,500 bytes. The workload uses the same read/write path, but these profiles do not attribute an exact fraction of its elapsed time to those copies. This is separate from the packed representation's retained-size improvement.

Optimized rb01 still calls key encoding 12,003 times in the 1,000-record profile, costing 0.939 instrumented CPU seconds and 972,295 allocations. Field dictionaries and bounded validated key caches target this repeated work directly. The archived [rb01 profiles](benchmarks/native-records/rb01-profiles.json.gz) retain method and append-size details.

In rb02, a literal six-field map occupies 116 bytes. A map using a field dictionary occupies 71 bytes, with one shared 62-byte dictionary per repeated shape. Original key slots directly preserve order and encodings. Short scans replace separate lookup and order indexes for up to sixteen members.

Ruby fidelity still has a storage cost. A value slot distinguishes types and preserves exact numeric representations. String payloads retain their encoding. Canonical key comparison can treat keys as equal while retaining the first key's original representation. Custom codec payloads retain their identifiers and bytes. These requirements do not require padded entry envelopes or separate indexes for small maps.

## Selected design

Core records contain an eight-byte header and at most thirty-two nine-byte slots. Their metadata selects the native container representation. Small arrays use up to sixteen slots. Larger arrays use sixteen-slot tree blocks and a compact wrapper. Construction holds at most sixteen slots per active tree level and writes each completed block once.

Small maps and sets preserve insertion order in their key slots. Maps with more than sixteen members, canonical keys larger than 128 bytes, or encoded key payloads larger than 256 bytes use the existing indexed representation. Value-only updates can reuse an existing field dictionary. Key changes can write a literal packed map.

Each encoding operation can share at most 256 short String or Symbol payloads and 64 field dictionaries. Identity includes scalar class, encoding, and exact bytes. Only values up to 64 source bytes qualify. Materialized mutable Strings remain independent Ruby objects. Dictionary read caches belong to a single read-only materialization operation; transaction reads do not retain them across mutations.

Large values remain separate byte records. String, Symbol, and codec payloads append with bounded prefixes and 64 KiB chunks. An update copies the affected record, bounded tree blocks on its ancestor path, and transaction history metadata. It does not decode unrelated array elements or oversized adjacent values.

The [wire contract](ruby-profile-v2.md) defines the exact record metadata, limits, rejection rules, and reserved profile identifiers.

## Production byte accounting and profiles

The production compactor accounts for every byte in the updated 10,000-record file. Memory and file probes produce the same ledger.

| Retained component | Bytes |
|---|---:|
| 10,000 row records, 71 bytes each | 710,000 |
| 669 array blocks and one array header | 96,352 |
| Array wrapper | 17 |
| Shared six-field dictionary | 62 |
| String payload records | 299,945 |
| Root map | 44 |
| File initialization, history, and trailers | 407 |
| Total | 1,106,827 |

String storage comprises 298,890 bytes for method names, 852 for shared namespaces and paths, and 203 for original keys. The 407-byte remainder contains a 37-byte header, two 160-byte history records, and two 25-byte trailers. One initialization history record and trailer are unreachable, a fixed 185 bytes that remain after compaction. The retained graph itself occupies 1,106,420 bytes.

The 891-byte nested-update growth has a direct structural explanation: one 71-byte row, four 144-byte array blocks, a 16-byte array header, a 17-byte wrapper, a 26-byte root map, 160 history bytes, and a 25-byte trailer. This is the affected path, not a replacement of the complete array.

Separate instrumented file probes measure the following logical store API traffic for 10,000 records. These are requested bytes and calls, not physical disk I/O. Compaction includes temporary mapping stores.

| Native operation | Read bytes | Written bytes | Read calls | Write calls |
|---|---:|---:|---:|---:|
| Insert | 1,154 | 1,106,762 | 31 | 50,820 |
| Full read | 1,731,495 | 0 | 110,745 | 0 |
| Three indexed reads | 11,363 | 0 | 461 | 0 |
| Identical reassignment | 1,644 | 1,106,579 | 56 | 50,815 |
| Nested update | 7,773 | 969 | 296 | 18 |
| Ten commits | 19,025 | 2,737 | 795 | 74 |
| Compaction | 24,843,657 | 14,767,778 | 387,207 | 309,905 |

Reopened indexed and complete reads have the same byte/call counts as the corresponding original-handle reads. Opening the file itself reads 651 bytes in twenty calls. JSON's three indexed reads request 1,160,289 bytes. Its nested update reads 1,161,760 and writes 1,159,844 bytes. Native's 969 written API bytes exceed its 891-byte file growth because writes also overwrite metadata.

Streaming scalar prefixes increase small write-call counts compared with the prototype's joined scalar payloads. This preserves bounded copying for oversized values while leaving scalar wire bytes unchanged. It is a measured trade-off, not an additional storage saving.

In the production 1,000-record file CPU profile, insert takes 0.480 instrumented CPU seconds. Input guards account for 0.303 seconds across 7,010 calls, about 63% of that total. Encoding dispatch costs 0.075 seconds across 12,001 calls; record append costs 0.00972 seconds across 1,003 calls. Only three checkpoints remain, capturing eleven cursor slots. Key encoding during a full read falls to three calls.

Complete read takes 0.135 instrumented CPU seconds. Scalar decoding accounts for 0.0606 seconds across 6,010 calls, record reads for 0.0304 seconds across 1,007 calls, and database reads for 0.0410 seconds across 11,142 calls. These inclusive costs overlap. The profiler adds allocations and method overhead; use the uninstrumented matrix for latency and allocation comparisons.

Compaction's temporary offset map remains a bottleneck after its 16,384-entry cache fills. Its traffic is much larger than the retained graph. The 1,000-record graph fits below that threshold, while the 10,000-record graph exceeds it. This explains the observed compaction scaling step without assuming proportional scaling from the smaller case.

## Alternatives and remaining costs

Ninety short serial prototype probes compared the previous indexed implementation, packed maps with incremental arrays, completed-block array construction, shared key payloads, field dictionaries, and validation changes. Each probe was a working implementation. The archive retains their sources and exact input.

The original packing study considered inline typed cells and larger byte chunks without implementing them. They might remove slot padding and scalar headers. They also require another parser and relocation rules, and can enlarge small update copies. The selected record design has direct measured evidence and preserves useful selective operations. It is not a demonstrated storage lower bound.

The follow-up [JSON performance experiments](benchmarks/native-pages/README.md) measure JSON pages, field dictionaries, column layouts, compressed pages, and typed binary pages. Those prototypes approach JSON bulk speed but do not implement the complete Ruby profile. Their update copying exceeds rb02's bounded record path.

Repeated validation was a separate CPU cost. A source-hashed 1,000-record probe reduced input-guard calls from 30,048 to 7,010 during insert, from thirteen to three during a full read, and from fifty-two to fifteen during an update. Exact immediate scalar classes skip per-object singleton inspection. Profile-owned validated encoding removes duplicate checks. Stored built-in keys do not repeat application-object introspection.

Unchanged reassignment still validates and encodes a complete new graph. There is no persistent whole-graph deduplication. A single-use dictionary can cost more than a literal map; the bounded dictionary table limits this extra cost. Large maps still have the earlier indexed representation's overhead. Full native reads still perform many small record and scalar decodes. Compaction uses a bounded offset cache and can spill mapping data to temporary storage.

The JSON control is faster for complete encoding and decoding on this workload. Its indexed reads and small updates decode the complete JSON payload, and its updates rewrite it. Native packing preserves typed values and selective operations. JSON-level native performance has not been established. Fixed nine-byte slots and repeated scalar encoding headers remain representation choices, not proven lower bounds; inline cells could reduce them further, but that benefit has not been measured.

## Correctness and verification

The implementation gate passed 489 tests and 41,640 assertions, with no failures, errors, or skips. Style, RBS validation, Steep, 100% typed calls across seventy library files, CRAP checks, packaged examples, and gem inspection passed through `bundle exec ruby script/ci.rb`. Focused native tests also passed on Ruby 3.3.11 and 3.4.9, each with 136 tests and 2,532 assertions.

Regression tests cover exact Float bits, numeric and String fidelity, canonical keys, insertion order, malformed records, threshold transitions, bounded builder behavior, snapshots, rollback, writer coordination, and failure injection. Independent review and QA include concurrent and reentrant materialization, malformed dictionary references, stored cycles, and mixed public mutations. The [review record](benchmarks/native-records/packing-review.md) states the review scope and same-family validation limit.

`bundle exec rake stress` passed five tests and 326 assertions. It retains the existing Linux memory suite and adds native workloads in Docker with 256 MiB memory and no swap. A 128 MiB String remains correct through append, snapshot retention, replacement, compaction, and reopen. A 12,500-record workload with 64 KiB values grows by 873 bytes for a small nested update and compacts to 820,684,940 bytes. Both native cases report zero OOM and OOM-kill events. Cgroup peaks reach the configured limit under reclaim pressure; this is not evidence of lower peak resident application memory.

`bundle exec rake interop` passed all four pinned Go, TypeScript, Java, and Zig reference checks. Portable storage, bidirectional all-kind values, history, compaction, interrupted replication, alternate hashing, and opaque Ruby scalar maintenance inside portable graphs remain covered. Existing pinned-reference numeric limits remain documented by that suite.

Native rb02 graphs use Core Record tag 17. Pinned reference implementations do not understand that extension and cannot maintain those graphs. Opaque Ruby scalar payloads remain unchanged and can still be maintained inside supported portable graphs. This is an intentional reduction of native container interoperability, not a claimed cross-language rb02 guarantee.

## Reproduction

The [final provenance](benchmarks/native-records/packing-final-provenance.json) records source/input hashes and SHA-256 digests for every compressed artifact.

| Evidence | Artifacts |
|---|---|
| Raw matrices | [Fresh paired samples](benchmarks/native-records/packing-final-samples.json.gz), [historical and resumed samples](benchmarks/native-records/rb01-complete-samples.json.gz) |
| Statistics | [Validated medians, ranges, allocations, and growth](benchmarks/native-records/packing-final-summary.json.gz) |
| Production diagnosis | [Traffic](benchmarks/native-records/packing-production-traffic.json.gz), [retained-byte ledgers](benchmarks/native-records/packing-production-bytes.json.gz), [CPU profiles](benchmarks/native-records/packing-production-profiles.json.gz) |
| Reproduction and checks | [Sources and exact input](benchmarks/native-records/packing-production-sources.json.gz), [verification evidence](benchmarks/native-records/packing-verification.json.gz) |

Run the comparison from this checkout. Its library files match the frozen packed revision; the report records the current commit. Checking out `af53aeb` separately reproduces the recorded candidate commit with the same timing driver.

After a squash merge, fetch the comparison commits from [PR #4](https://github.com/svyatov/xitdb-ruby/pull/4) before running the benchmark:

```sh
git fetch origin refs/pull/4/head
```

This fetch restores the optimized rb01 and frozen packed commits without changing the checkout.

```sh
bundle exec ruby script/native_benchmark.rb --baseline fde9a5dda601643398289f5bd0ebfdbfa7f2089e --output pkg/native-packed-final.json
```

Use `--resume` with the same candidate commit, options, Ruby, fixture, and driver to continue an interrupted run. The driver checks that provenance, then skips completed rows. For a short check, add `--counts fixture --stores file --samples 1 --warmups 0` and choose a different output path.

Run separate byte-traffic and retained-byte probes from this checkout. These extra instrumentation drivers were added after the timing freeze.

```sh
bundle exec ruby script/native_traffic.rb --count 10000 --store file --layout ruby --output pkg/native-traffic.json
bundle exec ruby script/native_byte_account.rb --count 10000 --store file --output pkg/native-byte-account.json
bundle exec ruby script/native_profile.rb --count 1000 --store file --output pkg/native-profile.json
```

`XITDB_LIBROOT` can select an extracted comparison revision. Traffic counts are logical store API requests, including repeated reads and temporary compaction stores, not operating-system disk traffic. The byte ledger counts first-time graph reservations during compaction and reports remaining file/history overhead separately.

Prototype replay commands, archived sources, and historical provenance are linked from the [experiment report](benchmarks/native-records/packing-design.md).
