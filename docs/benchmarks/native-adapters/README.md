# Typed pages through native views

Bounded typed pages work through the tested Ruby-profile transactions, views, sharing, and compaction paths. Whole-value reads still need improvement before claiming JSON parity.

This experiment extends the [page codec study](../native-pages/README.md) with native adapters. Production `lib/` remains at `b37aec2`.

## Results

The final matrix records elapsed time and process CPU time. Each storage mode has seven measured alternating pairs after one excluded warmup pair.

Median process CPU milliseconds for 10,000 synthetic records:

| Operation | File pages | File JSON | Memory pages | Memory JSON |
| --- | ---: | ---: | ---: | ---: |
| Insert | 3.344 | 3.954 | 2.749 | 3.200 |
| Whole-value read | 5.401 | 5.105 | 5.111 | 4.972 |
| Three indexed rows | 1.250 | 2.739 | 0.826 | 2.523 |
| One field update | 2.867 | 5.652 | 1.822 | 5.481 |
| Compact | 1.637 | 2.098 | 1.624 | 1.697 |

Median elapsed milliseconds for the same trials:

| Operation | File pages | File JSON | Memory pages | Memory JSON |
| --- | ---: | ---: | ---: | ---: |
| Insert | 3.436 | 4.258 | 2.747 | 3.199 |
| Whole-value read | 5.399 | 5.144 | 5.109 | 4.971 |
| Three indexed rows | 1.250 | 2.738 | 0.825 | 2.522 |
| One field update | 2.932 | 6.003 | 1.838 | 5.477 |
| Compact | 1.855 | 2.406 | 2.479 | 2.867 |

Read CPU medians exceed JSON by 5.8% for files and 2.8% for memory. Their ranges overlap, so these samples establish neither parity nor a stable regression size.

Elapsed page reads range from 5.266 to 5.600 ms for files and 5.062 to 6.061 ms for memory.

The first matrix measured elapsed time only. The second added CPU time. Both used the adapter before the deep-traversal and slice fixes.

JSON also became substantially faster in the final matrix. Absolute timings from different matrices are not directly comparable; all three matrices are retained.

Storage totals are identical across all three matrices and storage modes:

| Measurement | Pages | JSON |
| --- | ---: | ---: |
| Initial bytes | 455,217 | 1,160,301 |
| Compacted bytes | 455,218 | 1,160,015 |
| Bytes appended for one field update | 47,419 | 1,159,793 |

Pages reduce compacted storage by 60.8% and update bytes by 95.9%. Structural array edits use a different path, described below.

## Representation and operations

A native array record contains its logical count and a Core array of page references. Each typed page contains at most 1,024 rows and 65,536 payload bytes.

The codec accepts repeated flat Hash shapes with String keys. Cells preserve nil, booleans, immediate integers, Float bits, and String bytes with their encodings.

Array lookup creates a transient row descriptor containing the page and row index. Indexed decoding scans one bounded page and allocates only the requested row.

Sharing a row persists a record containing the page reference and row index. Core compaction can therefore follow every stored reference without understanding typed payloads.

A supported field update rewrites its page and ancestor references. Unsupported row updates replace that page with native row references and the changed native value.

Insertion, deletion, append, and truncation can promote the whole array to ordinary native storage. Promotion persists row references and avoids decoding their payloads.

Slice traversal decodes each visited page once and carries its decoded rows. Mixed pages use the iterative walker, preserving bounded Ruby call depth.

Bulk encoding uses a transaction checkpoint. If any page is unsupported, it restores bytes and resumes the original walker with its ancestor stack intact.

The experiment also uses the conservative compiled input guard from the page codec study. Singleton behavior returns to the original Ruby validation path.

## Method

`worker.rb` uses public profile operations for insert, materialization, indexed reads, field update, and compaction. JSON uses public portable byte storage with `JSON.generate` and `JSON.parse`.

Both timed read paths include the same equality check. Indexed reads check positions 0, 5,000, and 9,999. Exact scalar contracts run outside these timings.

Each worker runs in a separate process with fresh scratch storage. Garbage collection runs before each measurement, outside the measured interval.

File workers check reopen after compaction. Both modes check earlier snapshots and the compacted result. Memory reports omit reopen from their correctness labels.

The matrices contain 84 measured trials and 12 warmups. No benchmark workers overlap each other or the behavior tests. Operating-system cache state is uncontrolled.

The CPU matrices distinguish CPU consumption from elapsed delay. All matrices use the same operation sequence and data.

## Verification and limits

The dedicated contract passed nine tests with 51 assertions. It covers exact scalar bits and encodings, shared rows, slices, structural edits, rollback, cycles, and late fallback.

The stack regression failed with 871 Ruby frames at 40 nested levels before the fix. The revised traversal passed 400 levels within 128 frames.

The slice regression observed 1,024 row decodes before the fix. The revised boundary slice uses two page decodes; structural promotion performs no payload decodes.

Another 272 Ruby-profile and public behavior tests passed with 4,613 assertions. Package tests, type-coverage tests, and one physical rb02 row-layout test were excluded.

The excluded layout test reads rb02 records directly. Typed rows intentionally use a different physical representation; the dedicated contract checks their public behavior.

The broad-test runner requires the test files from checkout `b37aec2`; these are absent from the source archive. The advertised contract replay is self-contained.

Independent QA passed sharing through source deletion, compaction, reopen, copying, conversion, iteration, stream locks, oversized updates, and checkpoint fallback. Its reports remain outside the repository.

An earlier broad test invocation was interrupted after 433 tests. It selected unavailable Docker stress tests and external reference suites, plus the physical layout test.

That interrupted invocation is not a passing suite. The production library was unchanged, and this experiment did not rerun the full `bundle exec rake` gate.

The codec is experimental. Malformed-page validation needs duplicate-key checks, page row-count checks, and broader fuzzing before production integration.

The experiment uses private record metadata under an rb02 header. Its scratch databases are not a supported production format.

Extension packaging, a file-profile identifier, portable loading policy, crash injection, and cross-platform validation remain production requirements.

## Replay

The replay needs Ruby, its development headers, `make`, and a C compiler. The contract check also needs the repository's installed Minitest dependency.

```sh
ruby script/native_adapter_replay.rb --output /tmp/native-adapter.json
ruby script/native_adapter_replay.rb --check --output /tmp/native-adapter-checks.json
ruby script/native_adapter_replay.rb --variant json --store memory --output /tmp/native-adapter-json.json
```

Defaults are `pages`, 10,000 rows, and file storage. Variants are `pages`, `json`, `ruby`, and `guarded`; the latter applies only the compiled input guard.

The command verifies the source digest, extracts the archived library, and builds in a temporary directory. It refuses existing output paths and removes scratch builds.

## Artifacts

- `sources.json.gz`: exact library, adapters, codec, contract, workers, matrix driver, and analysis source.
- `samples.json.gz`: CPU and elapsed matrix, with every warmup and measured trial.
- `wall-samples.json.gz`: first elapsed-only matrix, run with archived `wall-worker.rb`.
- `cpu-before-samples.json.gz`: second matrix, before deep-traversal and slice fixes.
- `measured-sources.json.gz`: exact sources for both earlier matrices.
- `summary.json.gz`: final-matrix medians, ranges, allocations, and byte counts.
- `behavior-output.txt.gz` and `contract-output.txt.gz`: completed check output.
- `deep-before.txt.gz`, `deep-after.txt.gz`, and `slice-before.txt.gz`: traversal regression evidence.
- `provenance.json`: artifact digests and individual source digests.

The next optimization must reduce whole-value decode cost without losing selective updates or bounded traversal. These measurements do not complete the performance goal.
