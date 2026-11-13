# Typed-page encoding costs

The candidate avoids repeated schema-key comparisons and caches common encoding indices. It preserves the typed-page wire format and per-row Hash-behavior checks.

This extends the [snapshot-reference measurements](../snapshot-references/README.md) and [interned-key decoder](../native-decode/README.md). Production library files remain identical to `bd95e76`.

## Cause and change

The six-field dataset shares its six frozen key objects across rows. The baseline compares each key's encoding and bytes even when both references identify one object.

H1 checks object identity first. Distinct keys retain the original encoding and byte comparisons, including shape-mismatch rejection.

H2 initializes UTF-8, US-ASCII, and ASCII-8BIT encoding indices when the extension loads. String encoding uses those indices, resolving other encodings through Ruby's API.

The encoder retains three Hash-behavior calls per row: `default`, `default_proc`, and `compare_by_identity?`. The installed header marks direct default access as private and deprecated.

The experiment permits three hypotheses and requires at least 5% improvement. H1 and H2 pass the isolated threshold; H3, reducing buffer writes, remains untested.

## Isolated measurements

A balanced comparison loads baseline, H1, and H1+H2 as separately named C modules in one Ruby process. JSON generation provides an unchanged control.

Each observation encodes 10,000 rows ten times and reports CPU milliseconds per encoding. Four warmup rounds precede 32 measured rounds per variant.

| Variant | Median CPU ms | Range ms |
| --- | ---: | ---: |
| Baseline | 6.058 | 5.484-7.653 |
| H1 | 5.534 | 4.856-7.140 |
| H1+H2 | 5.125 | 4.696-7.213 |
| JSON generation | 5.401 | 4.861-6.267 |

H1 improves in 27 of 32 paired rounds; H2 improves on H1 in 27. The combined encoder improves in 30 rounds, with a median paired reduction of 15.2%.

H2's median paired reduction is 6.0%. The ratio of aggregate medians gives a different statistic, 7.4%; the archived samples preserve both comparisons.

Each measured encoder observation ends with a byte comparison against the baseline. These isolated timings exclude transactions, persistence, publication, and reads.

## Workflow measurements

The workflow comparison uses fresh databases and balanced orders in one process. Baseline and candidate share an identical public library and differ only in encoding.

Both page variants route encoding through the same Ruby wrapper to select their C module. Other operations use the unchanged public adapters and decoder.

The archived worker checks insert, full read, indexed read, update, historical snapshot, compaction, and file reopening. JSON controls use the same deterministic six-field rows.

The first matrix contains eight measured observations per variant, count, and store, plus one excluded warmup. Insert medians use process CPU milliseconds:

| Rows | Store | Baseline pages | Candidate pages | Core JSON |
| ---: | --- | ---: | ---: | ---: |
| 58 | File | 4.139 | 3.967 | 1.952 |
| 58 | Memory | 2.527 | 2.555 | 1.026 |
| 1,000 | File | 4.503 | 5.381 | 2.954 |
| 1,000 | Memory | 3.215 | 3.283 | 1.535 |
| 10,000 | File | 12.347 | 10.990 | 8.935 |
| 10,000 | Memory | 9.773 | 9.275 | 6.711 |

The 1,000-row file result appears slower despite improved isolated encoding. Unchanged operations also vary substantially, so a focused insert comparison follows.

That comparison prepares ten fresh databases before each timed observation. It times ten inserts, divides by ten, and checks every database after timing.

Each variant receives twelve measured observations per count and store, plus one excluded warmup. All six variant orders repeat twice.

| Rows | Store | Baseline CPU ms | Candidate CPU ms | Core JSON CPU ms | Candidate wins |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1,000 | File | 3.633 | 3.624 | 2.012 | 6/12 |
| 1,000 | Memory | 2.271 | 2.068 | 1.100 | 9/12 |
| 10,000 | File | 11.796 | 10.462 | 9.633 | 10/12 |
| 10,000 | Memory | 9.014 | 8.632 | 6.584 | 8/12 |

The apparent 1,000-row file regression does not repeat; that result is inconclusive. At 10,000 rows, the median paired CPU reductions are 12.2% for files and 11.3% for memory.

The memory evidence is weaker, with four slower candidate observations. Its ratio of aggregate medians gives a 4.2% reduction, below the isolated experiment's 5% threshold.

At 10,000 rows, file CPU ranges are 10.726-14.597 ms for baseline pages and 8.377-11.927 ms for the candidate. Memory ranges are 8.417-12.636 and 6.952-13.459 ms.

File elapsed medians worsen from 17.268 to 18.394 ms. Memory elapsed medians improve from 16.108 to 12.794 ms, with overlapping ranges.

These results support reduced encoder CPU and lower large-file insert CPU. They establish neither a general latency improvement nor parity with Core JSON.

Other operations at 10,000 rows in the first matrix, using process CPU milliseconds:

| Operation | File baseline | File candidate | File Core JSON | Memory baseline | Memory candidate | Memory Core JSON |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Whole read | 16.440 | 15.910 | 17.385 | 14.338 | 14.368 | 15.914 |
| Three indexed rows | 3.516 | 3.437 | 8.542 | 2.491 | 2.709 | 8.253 |
| One field update | 13.939 | 11.592 | 17.363 | 7.179 | 7.580 | 14.831 |
| Compact | 8.211 | 8.698 | 6.902 | 7.496 | 7.124 | 6.290 |

These operations provide compatibility and regression evidence; they do not establish general improvements from the encoder change.

At 10,000 rows, page variants retain identical sizes: 455,218 compacted bytes and 47,419 appended bytes per update. Core JSON uses 1,159,513 and 1,159,451 bytes, respectively.

## Controls and limits

Initial process-isolated probes show substantial drift: unchanged JSON costs differ by 17% between variant processes. Those samples do not establish a candidate improvement.

The first copied Makefile also targets the baseline source directory. Regenerating the candidate Makefile and rebuilding corrects that harness error before paired comparisons.

The same-process method reduces process-placement differences. Garbage collection runs before each operation; CPU scheduling and operating-system caches remain uncontrolled.

Both workflow matrices run after all QA and test workloads stop. The first contains 192 measured observations and 24 warmups; the insert repeat contains 144 and twelve.

Absolute times are specific to this run on Darwin 27.2.0 arm64. Hardware-detail queries are blocked by the execution sandbox; the runtime appears in `provenance.json`.

Typed pages remain experimental. Production integration requires format identification, malformed-page hardening, packaging, type coverage, and platform validation.

## Verification and replay

Codec checks pass 430 cases across all 103 installed encodings, preserving exact keys, mutable values, Float bits, selected rows, and GC-compaction behavior.

The encoded-byte digest is `044ef6d8c17cd70ac78e8cbacd1edc8a4ab8f4c6e3eef0850e218160da75ad5a`. Archived public contracts pass ten tests and 54 assertions.

The five encoding APIs are declared in Ruby's upstream 3.3 header. Runtime verification uses the Ruby version recorded in the manifest.

Independent QA matches 57 behavioral groups and ten edge checks between variants, covering both stores, all encodings, fallback, rollback, snapshots, and byte limits.

QA also observes two indexed `decode_row` calls in both variants. This pre-existing cost remains outside the encoder change; neither variant decodes the whole page.

Fresh source review finds no encoder or replay defect. The replay script passes Ruby syntax and RuboCop checks; production library files have no changes.

Replay the candidate and the direct Core JSON control:

```sh
ruby script/native_adapter_replay.rb --study encode --output /tmp/native-encode.json
ruby script/native_adapter_replay.rb --study encode --check --output /tmp/native-encode-checks.json
ruby script/native_adapter_replay.rb --study encode --variant core_json --output /tmp/native-encode-core.json
```

Output paths must not exist. Building the page variant requires Ruby headers, `make`, and a C compiler. No package installation is required.

The replay option first fails as unsupported, then passes after the option is added. Seven CLI scenarios cover page and JSON workers, older studies, and output protection.

`sources.json.gz` contains the candidate library, extension, adapters, contracts, and workers. The provenance manifest records source and artifact digests.

For the full comparison, extract the `files` mapping from `harness.json.gz` into a scratch directory:

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

1. Run `ruby extconf.rb` inside the extracted `baseline/` directory.
2. Run `make` in that directory.
3. From its parent, run `ruby build_paired.rb baseline candidate encoding`.
4. Run `ruby paired_matrix.rb` to produce workflow samples.
5. Run `ruby summarize_matrix.rb` to verify and summarize the samples.

`paired_probe.rb` repeats H1's isolated comparison. `paired_encoding.rb` repeats the combined encoder comparison. These drivers write their samples beside the extracted sources.

`insert_matrix.rb` repeats the focused insert comparison. Run `ruby summarize_inserts.rb` to produce its medians, ranges, and paired ratios.

Files labeled `initial-probes` preserve the stale-build attempt. `drifted-probes` preserves the corrected process comparison whose JSON control drifted.
