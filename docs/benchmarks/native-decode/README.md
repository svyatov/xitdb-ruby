# Interned keys in typed pages

Interning decoded keys reduces checked whole-value reads by 17.8% for files and 16.2% for memory at 10,000 rows.

The candidate also beats direct Core JSON reads at that size. Smaller datasets and insert costs still prevent the broader performance target from being met.

This extends the [native adapter experiment](../native-adapters/README.md). Production `lib/` remains unchanged at `b31f1b0`.

## Cause and change

The baseline decoder freezes a separate key String for each page. JSON 3.1.0 interns decoded keys through Ruby's extension API.

The candidate replaces `rb_obj_freeze(key)` with `rb_str_to_interned_str(key)`. Immutable keys can share Ruby's interned representation; mutable String values remain independent.

The identity probe finds zero shared keys in the baseline and six in the candidate, both against input keys and across decodes. Neither shares mutable values.

An isolated probe separates decoding from equality checks. Baseline raw public materialization takes 2.079 ms, compared with JSON's 2.282 ms.

Adding equality checks raises those medians to 5.154 and 4.656 ms. The candidate probe measures 1.824 ms raw and 4.306 ms checked.

Those probes identify the cause; the interleaved matrix below measures the result. The improvement includes faster materialization and cheaper comparisons of reconstructed hashes.

The experiment budget allowed three hypotheses, targeting at least 5% improvement. Key interning passed; Hash capacity and encoding-specific String constructors were not tested.

## Results

The final matrix has eight measured observations per variant, count, and store. Every group also has one excluded warmup.

Whole-value read medians use process CPU milliseconds and include identical equality checks:

| Rows | Store | Baseline pages | Interned pages | Public JSON | Direct Core JSON |
| ---: | --- | ---: | ---: | ---: | ---: |
| 58 | File | 0.360 | 0.361 | 0.279 | 0.103 |
| 58 | Memory | 0.249 | 0.249 | 0.232 | 0.087 |
| 1,000 | File | 0.810 | 0.733 | 0.719 | 0.554 |
| 1,000 | Memory | 0.694 | 0.610 | 0.667 | 0.518 |
| 10,000 | File | 5.392 | 4.432 | 5.100 | 4.894 |
| 10,000 | Memory | 5.154 | 4.318 | 4.973 | 4.854 |

At 10,000 rows, interned pages use 9.5% less read CPU than direct Core JSON for files and 11.1% less for memory.

File read ranges are 4.347-4.684 ms for interned pages and 4.839-4.986 ms for Core JSON. Memory ranges are 4.196-4.667 and 4.681-5.284 ms.

Elapsed read medians are 4.430 ms for candidate files and 4.321 ms for candidate memory. Core JSON takes 4.893 and 4.853 ms, respectively.

Other operations at 10,000 rows, in process CPU milliseconds:

| Operation | File pages | File public JSON | File Core JSON | Memory pages | Memory public JSON | Memory Core JSON |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Insert | 3.252 | 4.005 | 2.205 | 3.029 | 3.194 | 1.775 |
| Three indexed rows | 1.208 | 2.666 | 2.464 | 0.822 | 2.508 | 2.383 |
| One field update | 2.692 | 5.748 | 4.927 | 1.799 | 5.549 | 4.895 |
| Compact | 1.601 | 2.011 | 1.484 | 1.627 | 1.698 | 1.340 |

Memory insert medians are 3.029 ms for the candidate and 2.823 ms for the baseline. Their ranges overlap: 2.682-3.205 and 2.695-3.136 ms.

The insert difference is unresolved; these observations establish no insert improvement. The encoder source is identical, and the file insert medians are nearly equal.

Stored bytes are unchanged by key interning. At 10,000 rows, pages retain 455,218 compacted bytes and append 47,419 bytes for one field update.

Direct Core JSON retains 1,159,513 compacted bytes and appends 1,159,451 bytes. Public JSON retains 1,160,015 bytes and appends 1,159,793 bytes.

## Controls and limits

Public JSON uses a byte value under the public root map's `data` key. Pages use the same public location and native views.

Direct Core JSON stores one byte value directly in the Core root. It includes serialization, parsing, transactions, snapshots, compaction, and reopening.

The direct control omits public root-map and view dispatch costs. It provides a stricter latency comparison, not an equivalent collection API.

All datasets contain deterministic synthetic rows with six fields. The 58-row case is synthetic, not the separate analyzer fixture used in earlier studies.

Each worker starts in a fresh Ruby process and fresh storage. Garbage collection runs before each operation; OS caches remain uncontrolled.

The final driver repeats four balanced orders twice. Each variant occupies every order position twice; directed predecessor pairs also balance.

The first driver combined rotation with reversal, leaving variant positions uneven. Its 168 measured observations and 24 warmups remain archived separately.

The balanced repeat contains 192 measured observations and 24 warmups. Matrix workers never overlap each other, tests, or independent QA workloads.

Both matrices support the large-read improvement. Their small-case and insert results remain visible in the raw samples and summaries.

## Verification

The final contract replay passes ten tests and 54 assertions. Its encoding check covers 430 cases across all 103 installed encodings.

The checks preserve exact key bytes, encodings, Float bits, independent mutable values, zero-to-sixteen-field rows, selected rows, and GC compaction.

Baseline and candidate checks produce the same encoded-byte digest. This change affects reconstruction only; it changes no page bytes.

The relevant Ruby-profile and public suite passes 272 tests and 4,613 assertions. Exclusions match the adapter study: package, type coverage, and physical rb02 row layout.

Independent QA passes encoded keys, page boundaries, sharing, snapshots, compact/reopen, twenty GC-compaction mutation cycles, and selected decoding under GC stress.

The replay-selection check first fails because `--study` is unsupported. It passes after adding study selection, with default behavior and output protection preserved.

The initial probe loaded both archive and checkout libraries. Explicit `XITDB_PROBE_ROOT` selection fixes that harness error; the retained probe output comes from the corrected run.

Production integration still requires malformed-page hardening, a file-profile identifier, extension packaging, type coverage, package checks, crash tests, and platform validation.

## Replay and evidence

Run the candidate or direct Core JSON control through the archived library:

```sh
ruby script/native_adapter_replay.rb --study decode --output /tmp/native-decode.json
ruby script/native_adapter_replay.rb --study decode --check --output /tmp/native-decode-checks.json
ruby script/native_adapter_replay.rb --study decode --variant core_json --output /tmp/native-decode-core.json
```

Omitting `--study` retains the original adapter experiment. Output paths must not exist. Candidate builds require Ruby headers, `make`, and a C compiler.

`sources.json.gz` contains the candidate library, codec, adapters, contracts, and measurement scripts. The baseline archive and its digest appear in `provenance.json`.

The complete matrix driver expects compiled `baseline/` and `candidate/` directories beside it. Single-worker and contract replay extract and build automatically.

`samples.json.gz` and `summary.json.gz` preserve the balanced matrix. Files prefixed with `initial-` preserve the first matrix.

Probe, identity, codec, contract, behavior, and replay outputs retain the supporting evidence. The provenance manifest records every compressed artifact and source digest.

The next performance work must reduce fixed adapter costs and bulk-insert overhead. Large-read speed alone does not complete the active goal.
