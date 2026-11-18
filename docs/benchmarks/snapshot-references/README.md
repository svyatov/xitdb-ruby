# Retained snapshot references

Snapshot views retain their resolved immutable slot, removing repeated ancestor traversal from subsequent reads. Transaction views continue to resolve their live locations.

At 40 nested maps, retained Ruby-profile reads fall from 8.750 to 0.027 ms for files and from 7.498 to 0.021 ms for memory.

This production change improves both profiles. The [typed-page experiment](../native-decode/README.md) remains separate, and bulk inserts still exceed direct Core JSON costs.

## Change and constraints

`Context#view` passes its resolved `Core::Slot` into `Views::Base`. A view retains the slot only when its context has no transaction.

Every read still enters the context's operation guard and checks storage and view lifetimes. Captured bounds and reference-sharing checks remain in effect.

Each view retains one immutable descriptor. The implementation adds no adapter cache, decoded-value cache, persistent format, or dependency.

## Production measurements

The dataset has one root key, `data`, followed by either one or forty nested `child` maps ending in `[1, 2, 3]`.

Each observation selects the leaf five times and materializes a retained leaf fifty times. The table reports median process CPU milliseconds per operation.

| Profile | Store | Nested maps | Baseline selection | Candidate selection | Baseline retained read | Candidate retained read |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Portable | File | 1 | 0.388 | 0.292 | 0.404 | 0.033 |
| Portable | File | 40 | 79.545 | 4.160 | 7.557 | 0.034 |
| Portable | Memory | 1 | 0.339 | 0.251 | 0.374 | 0.026 |
| Portable | Memory | 40 | 72.583 | 3.776 | 7.024 | 0.025 |
| Ruby | File | 1 | 0.507 | 0.397 | 0.461 | 0.028 |
| Ruby | File | 40 | 95.349 | 6.122 | 8.750 | 0.027 |
| Ruby | Memory | 1 | 0.404 | 0.313 | 0.424 | 0.024 |
| Ruby | Memory | 40 | 79.961 | 4.791 | 7.498 | 0.021 |

At depth forty, portable storage reads fall from 249 to three, and Ruby storage reads fall from 576 to two. Candidate counts also hold at depth one.

Ruby allocations per retained read fall from 13,111 to 71 for files and from 11,959 to 67 for memory at depth forty.

File CPU ranges are 8.597-9.176 ms for baseline Ruby reads and 0.026-0.031 ms for the candidate. Memory ranges are 7.399-7.558 and 0.021-0.024 ms.

Elapsed medians closely match CPU medians: Ruby file reads take 8.765 and 0.027 ms, while memory reads take 7.506 and 0.021 ms.

## Typed-page compatibility measurements

The second matrix uses the archived typed-page codec and public adapters, with only the production library changed between baseline and candidate.

Whole-value reads include equality checks. Indexed reads materialize and check the first, middle, and last rows of deterministic six-field records.

| Rows | Store | Baseline whole read | Candidate whole read | Core JSON whole read | Baseline indexed | Candidate indexed | Core JSON indexed |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 58 | File | 0.351 | 0.311 | 0.100 | 1.087 | 0.582 | 0.086 |
| 58 | Memory | 0.247 | 0.218 | 0.088 | 0.700 | 0.401 | 0.072 |
| 1,000 | File | 0.734 | 0.681 | 0.560 | 1.198 | 0.687 | 0.307 |
| 1,000 | Memory | 0.607 | 0.579 | 0.521 | 0.774 | 0.472 | 0.283 |
| 10,000 | File | 4.385 | 4.414 | 4.929 | 1.211 | 0.693 | 2.464 |
| 10,000 | Memory | 4.245 | 4.279 | 4.719 | 0.810 | 0.519 | 2.318 |

Times are process CPU milliseconds. At 10,000 rows, indexed reads improve by 42.8% for files and 35.9% for memory.

Large whole-value reads show no improvement. Candidate inserts take 3.413 ms for files and 2.825 ms for memory, versus Core JSON's 2.207 and 1.771 ms.

The source change leaves encoding and transaction paths intact. These samples establish no improvement in inserts, updates, or compaction.

## Method and limits

The baseline library matches commit `99711f8`. Both variants use frozen source copies; every library digest is verified against Git or the measured working tree.

Production measurements contain eight alternating measured pairs per profile, store, and depth, plus one excluded warmup pair. Each worker uses a fresh process and database.

That matrix contains 128 measured observations and sixteen warmups. Equality checks and instrumented storage-read counts run outside its timed operations.

The adapter matrix contains 192 measured observations and 24 warmups. Its four balanced variant orders repeat twice, following the decoder study's method.

Public JSON and direct Core JSON controls use the baseline library. Direct Core JSON omits public root-map and view dispatch costs.

Garbage collection runs before each timed operation. Workers run sequentially, without overlapping tests or QA workloads. Operating-system caches remain uncontrolled.

All measurements use the Ruby runtime recorded in `provenance.json`. These results cover one machine and synthetic datasets; they do not establish general JSON parity.

## Verification

The regression first fails with nine shallow portable reads versus 249 deep reads. Both profiles pass after the change, with two tests and 36 assertions.

`bundle exec rake` passes 491 tests and 41,676 assertions, RuboCop, RBS validation, Steep, 100% typed calls, coverage, and the CRAP threshold of ten.

Independent QA passes 26 scenarios on each variant. It covers all collection kinds, slices, sharing, rollback, expiration, concurrent readers, captured bounds, compaction, reopening, and closure.

The QA dataset includes separate shallow and deep root keys, producing a different baseline Ruby read count from this benchmark. Both candidates require two reads.

Fresh source review finds no actionable issue. Archived typed-page contracts also pass ten tests and 54 assertions against the changed production library.

## Replay and evidence

Extract `sources.json.gz` into a scratch directory using Ruby's standard library:

```ruby
require "json"
require "zlib"
require "fileutils"
archive, destination = ARGV
files = Zlib::GzipReader.open(archive) { |io| JSON.parse(io.read).fetch("files") }
files.each do |name, content|
  path = File.join(destination, name)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
end
```

Run `ruby snapshot_matrix.rb` from the extracted directory. It writes `snapshot_samples.json`; `ruby summarize.rb snapshot_samples.json` generates its summary.

For the adapter matrix, run `ruby extconf.rb` and `make` inside each extracted variant directory. Then run `ruby matrix.rb` from their parent directory.

The adapter build requires Ruby headers, `make`, and a C compiler. Run `ruby summarize.rb samples.json` to summarize its output.

Compressed samples preserve every observation, including warmups. Summaries retain CPU, elapsed, and allocation medians and ranges. QA and quality-gate outputs retain verification evidence.

`provenance.json` records source and artifact digests. No generated extension binary is archived.
