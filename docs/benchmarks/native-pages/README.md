# Experiments toward JSON performance

The production Ruby profile still misses the JSON performance target. These experiments identify faster representations and separate storage costs from Ruby execution costs.

A bounded binary page prototype approaches JSON bulk-read time while reducing stored bytes and selective-operation latency. It does not implement the complete Ruby profile.

## Findings

The final comparison measures the production library at `f77066f` and experimental page layouts. Each case has one excluded warmup and three measured samples.

For 10,000 records in a file, median times are milliseconds. Indexed reads select three rows. Compacted bytes contain the updated latest state.

| Layout | Insert | Full read | Indexed reads | Nested update | Compaction | Compacted bytes | Update growth |
|---|---:|---:|---:|---:|---:|---:|---:|
| Production rb02 | 3,623.504 | 755.170 | 3.315 | 4.106 | 3,164.302 | 1,106,827 | 891 |
| Public JSON control | 3.794 | 5.036 | 2.632 | 5.854 | 2.047 | 1,160,053 | 1,159,793 |
| Core JSON control | 2.543 | 4.953 | 2.921 | 7.434 | 1.859 | 1,160,019 | 1,159,797 |
| Typed pages, 256 rows | 3.250 | 5.386 | 0.336 | 0.839 | 2.086 | 457,580 | 12,230 |
| Typed pages, 1,024 rows | 2.873 | 5.058 | 0.832 | 1.115 | 1.479 | 455,169 | 47,032 |

The 1,024-row layout retains 60.8% fewer bytes than JSON and 58.9% fewer than rb02. Its full-read median remains slightly slower than JSON.

File read samples span 5.042-5.097 ms for typed pages and 4.983-5.040 ms for public JSON. Memory medians are 5.099 and 4.904 ms, respectively.

These results do not prove read-speed parity. A production implementation must include public view dispatch, all applicable validation, and the full Ruby value contract.

Larger pages improve bulk work but increase update copying. The 1,024-row prototype adds 47,032 bytes for one field change, compared with rb02's 891 bytes.

The following table compares public JSON and 1,024-row typed pages across all datasets. Each cell shows JSON / prototype medians in milliseconds.

| Records | Store | Insert | Full read | Indexed reads | Nested update |
|---:|---|---:|---:|---:|---:|
| 58 | memory | 1.397 / 0.312 | 0.232 / 0.128 | 0.213 / 0.101 | 0.847 / 0.331 |
| 58 | file | 1.887 / 0.521 | 0.291 / 0.148 | 0.273 / 0.134 | 1.263 / 0.588 |
| 1,000 | memory | 1.555 / 0.513 | 0.686 / 0.571 | 0.434 / 0.299 | 1.230 / 0.673 |
| 1,000 | file | 1.916 / 0.761 | 0.712 / 0.601 | 0.478 / 0.333 | 1.567 / 0.987 |
| 10,000 | memory | 2.977 / 2.551 | 4.904 / 5.099 | 2.478 / 0.767 | 4.949 / 0.744 |
| 10,000 | file | 3.794 / 2.873 | 5.036 / 5.058 | 2.632 / 0.832 | 5.854 / 1.115 |

## Representations and validation

JSON row pages retain complete hashes. Schema pages store field names once and encode each row as an array of values. Column pages transpose those arrays.

Schema pages reduce stored bytes, but Ruby hash reconstruction costs more than direct JSON parsing. In the accelerated comparison, 256-row schema reads take 11.398 ms.

Moving that reconstruction to C reduces reads to 7.066 ms. Direct JSON row pages take 5.380 ms in the same comparison.

Deflate compression produces 94,976 compacted bytes for this repetitive dataset. Its initial screening insert takes 4.656 ms. General compression benefits remain workload dependent.

The typed prototype stores field names once per page and writes tagged scalar cells directly into a 64 KiB buffer. Pages contain at most 1,024 rows.

It supports nil, booleans, Fixnum integers, exact Float bits, and String bytes with encoding identifiers. Keys must be Strings with identical order and representation across rows.

The encoder rejects subclasses, singleton classes, Hash defaults, identity comparison, oversized cells, and pages exceeding 64 KiB. Rejection does not invoke a production fallback.

The decoder constructs hashes in C. It has bounded counts and truncation checks, but lacks production checks such as duplicate-key rejection and canonical varint validation.

A separate C guard checks whether an object has its ordinary class. Objects with singleton classes retain the original Ruby validation path.

That guard reduces rb02 insert time from 3,591.019 to 787.226 ms in the accelerated comparison. Full reads remain 757.419 ms. Validation alone cannot meet the target.

Calling the accelerated guard separately for every page value still costs 14.964 ms per insert. Scanning rows in C reduces that figure to 4.035 ms.

The original Ruby guard probe takes 7,337.048 ms because it checks every key and value without the production key cache. It is a cost probe, not equivalent validation.

## Method and limits

Workers run serially in fresh Ruby processes, reversing variant order between samples. Library loading is excluded. Each measured operation starts after a full GC.

The runtime is Ruby 4.0.9 on arm64 macOS. Experimental C code uses Apple clang 21.0.0. No dependency or extension was added to the gem.

The 58-record fixture and deterministic 1,000- and 10,000-record datasets match the [production benchmark](../../native-profile-performance.md). Archives retain the exact fixture, library, scripts, and source hashes.

Pages use Core byte records, an indexed page tree, a two-field root record, and ordinary transaction history. They bypass the public native adapters and logical root map.

The Core JSON control uses the same experimental wrapper with one complete JSON payload. This exposes wrapper costs separately from public JSON overhead.

Every page worker checks roundtrip values, indexed reads, updates, retained snapshots, rollback, latest-state compaction, and file reopening where applicable. JSON serialization is included in timings.

The accelerated, typed, and final comparisons include equality checks within timed reads. Production native reads additionally check key order and String encodings.

The initial screening comparison excludes equality checks from page read timings and decodes a shared page repeatedly during indexed reads. Do not compare its read latencies directly.

The five archived matrices contain 178 measured trials and 62 excluded warmups. These are exploratory samples, not the required seven-sample production acceptance matrix.

OS caches were not flushed. Local editing and a short style check overlapped parts of the exploration. These results do not establish isolated-machine or cold-disk performance.

The page prototypes do not support arbitrary nested values, application codecs, large integers, sorted containers, public mutable views, or graph conversion. Oversized rows require another representation.

Compaction preserves opaque pages through Core byte storage. This does not prove native-profile conversion, fault recovery, writer coordination, or Linux memory behavior for an integrated implementation.

## Verification and replay

The conservative C guard passed the existing 489-test suite with 41,640 assertions. This verifies that helper against existing tests, not the typed-page representation.

The typed decoder passed 18 scalar cases, including exact NaN bits, signed zero, invalid UTF-8 bytes, and UTF-16LE. It rejected all 123 truncated prefixes.

The scalar probe also checks oversized-cell and singleton-behavior rejection. Replay checks storage, updates, snapshots, compaction, rollback, and reopen against archived inputs.

Run a 10,000-record file replay from the repository. It builds the experimental extension in a temporary directory and deletes that directory afterward.

```sh
ruby script/native_page_replay.rb --output /tmp/native-page-replay.json
```

Use `--variant json` for the public JSON control or `--variant rows:0` for the Core control. Use `--variant typed:256` for smaller pages.

`--stage accelerated --variant ruby_native_guard` replays the isolated guard experiment. Variants must occur in the selected stage's archived samples. Counts accept `fixture` or positive integers.

Output paths must not exist. Ruby development headers and `make` are required for stages containing C.

The [provenance manifest](provenance.json) records archive digests. [Sources](sources.json.gz) include each measured prototype revision and the library used by every worker.

[Summaries](summary.json.gz) retain medians, ranges, allocations, sizes, and update growth. Raw samples are archived separately for [screening](screen-samples.json.gz), [acceleration](accelerated-samples.json.gz), [typed smoke checks](typed-smoke-samples.json.gz), [bulk reconstruction](typed-bulk-samples.json.gz), and the [final comparison](final-samples.json.gz).

The extension experiment follows Ruby's [extension API documentation](https://docs.ruby-lang.org/en/master/extension_rdoc.html) and the installed Ruby 4.0 headers. Compatibility with other Ruby versions remains unverified.

## Next experiment

The follow-up [compiled rb02 experiment](../native-batch/README.md) measures batching without replacing the storage format. It separates implementation-language costs from page-layout costs.

The [native adapter experiment](../native-adapters/README.md) measures typed pages through public Ruby-profile views, transactions, sharing, and compaction. It includes general-value fallback and bounded iterative traversal.

Preserve rb02's bounded update path as a comparison point. Measure byte traffic and peak memory in addition to elapsed time and retained size.

Only select a production representation after measuring it through public transactions and views. Require exact scalar fidelity, general-value fallback, corruption checks, and mutation semantics.

Complete the full quality, compatibility, memory, and seven-sample performance gates after integration. The original performance goal remains active.
