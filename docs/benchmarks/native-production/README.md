# Production native pages

Commit `9e1ebd13f7b14d162c4659cd8c2facea5308d74e` integrates bounded typed pages into the Ruby profile under format identifier `rb03`.

At 10,000 rows, pages reduce full-read, selected-read, and update CPU costs against direct Core JSON. Inserts and smaller datasets remain slower.

## Method

The benchmark loads production code directly from the checkout. It compares the Ruby profile, direct Core JSON, and JSON stored through the public portable API.

Each group receives two excluded warmups and twelve measured observations. All six variant orders repeat twice in one process, with garbage collection before each operation.

The deterministic dataset contains six-field flat Hash rows. Counts are 58, 1,000, and 10,000; each runs against file and memory stores.

Each observation checks insertion, full reads, three selected rows, a single-field update, the previous snapshot, compaction, and file reopening where applicable.

Read measurements include equality checks. Setup, verification outside measured operations, and garbage collection are excluded; transactions and persistence are included.

## CPU results

The table reports paired median Ruby-profile/Core-JSON CPU ratios. Values below one favor the Ruby profile.

| Rows | Store | Insert | Full read | Three rows | Update | Compact |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 58 | File | 3.23 | 3.81 | 6.65 | 10.85 | 1.59 |
| 58 | Memory | 4.13 | 3.44 | 5.65 | 14.48 | 1.49 |
| 1,000 | File | 2.46 | 1.36 | 2.01 | 5.59 | 1.46 |
| 1,000 | Memory | 2.79 | 1.23 | 1.60 | 5.63 | 1.50 |
| 10,000 | File | 1.38 | 0.92 | 0.27 | 0.87 | 1.05 |
| 10,000 | Memory | 1.51 | 0.90 | 0.23 | 0.76 | 1.12 |

At 10,000 rows, full reads, selected reads, and updates win all twelve paired CPU observations on both stores. Inserts lose all twelve.

File insert CPU medians are 2.891 ms for pages and 2.080 ms for Core JSON. Memory medians are 2.554 ms and 1.700 ms.

Small-update overhead remains substantial: 58-row file medians are 3.589 ms for pages and 0.330 ms for Core JSON.

## Space and elapsed time

Both stores produce identical sizes. At 10,000 rows, pages compact to 455,218 bytes; Core JSON compacts to 1,159,513 bytes, a 60.7% reduction.

A single update appends 47,419 bytes with pages and 1,159,451 bytes with Core JSON, a 95.9% reduction.

At 58 rows, the corresponding compacted sizes are 3,218 and 6,698 bytes. An update appends 3,333 and 6,636 bytes.

At 10,000 rows, paired median elapsed insert ratios are 1.23 for files and 1.51 for memory. Both miss parity.

Compaction has lower elapsed ratios, 0.88 on both stores, despite higher CPU ratios. CPU and elapsed evidence therefore support different conclusions for that operation.

## Verification and limits

The production gate passes 519 tests and 42,464 assertions, style checks, RBS, Steep, 100% typed calls, and the complexity threshold.

Independent public API QA passes 280 differential operations across four row counts, plus malformed storage, callback, stream, snapshot, conversion, and writer checks.

Fresh source review reports no remaining defect. Runtime verification uses Ruby 4.0.9 on Darwin 27.2.0 arm64; Linux and other Ruby versions remain unverified.

The matrix contains 216 measured observations and 36 warmups. Test and QA workloads stopped before measurement; system scheduling and filesystem caches remain uncontrolled.

One flat-row dataset does not establish general workload performance. These results leave the overall Core JSON parity target unmet.

## Replay

`provenance.json` records the commit, runtime, production source hashes, native binary hash, and archive hashes. Raw samples preserve CPU, elapsed time, allocations, sizes, and correctness outcomes.

`harness.json.gz` contains four Ruby scripts without prototype adapters. Extract its `files` mapping into a scratch directory:

```ruby
require "json"
require "zlib"
require "fileutils"
archive, destination = ARGV
files = Zlib::GzipReader.open(archive) { |io| JSON.parse(io.read).fetch("files") }
FileUtils.mkdir_p(destination)
files.each { |name, content| File.write(File.join(destination, name), content) }
```

1. Check out the recorded commit in an isolated directory.
2. Run `bundle exec rake compile` there to build its native extension.
3. Run `ruby /scratch/benchmark.rb /checkout /scratch/samples.json`.
4. Run `ruby /scratch/summarize.rb /scratch/samples.json /scratch/summary.json`.

Output files must not exist. The driver rejects source changes during measurement; the summarizer checks sample counts, dataset identities, and stable byte sizes.
