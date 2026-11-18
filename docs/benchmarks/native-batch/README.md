# Compiled batching with the rb02 format

This experiment tests whether compiled bulk operations can match JSON while preserving rb02 records and small updates. The production library remains unchanged.

The prototype batches writes, reconstructs Ruby values in C, and reads through bounded buffers. It uses public native transactions, snapshots, views, and compaction.

## Results

Compiled batching reduces interpreter overhead while preserving 891-byte updates. This implementation still misses JSON bulk latency and leaves Ruby compaction unchanged.

The optimized 10,000-record comparison has three measured samples and one excluded warmup per variant. Times are medians in milliseconds.

| Store | Implementation | Insert | Full read | Three indexed reads | Nested update | Compaction |
|---|---|---:|---:|---:|---:|---:|
| File | Public JSON | 21.880 | 28.634 | 19.309 | 40.665 | 22.061 |
| File | Compiled rb02 | 41.126 | 47.431 | 18.821 | 25.731 | 29,481.998 |
| Memory | Public JSON | 17.982 | 28.859 | 13.745 | 37.947 | 17.213 |
| Memory | Compiled rb02 | 36.452 | 38.975 | 7.853 | 16.442 | 21,142.131 |

The file prototype is 1.88 times slower on insert and 1.66 times slower on full reads. Indexed-read medians are close and do not establish parity.

File read samples range from 34.064 to 70.805 ms for the prototype and 28.397 to 41.621 ms for JSON. The ranges overlap.

Whole-worker peak memory medians are 68,730,880 versus 52,936,704 bytes in files, and 73,056,256 versus 50,561,024 bytes in memory, for native versus JSON.

Compacted native storage remains 1,106,827 bytes, compared with JSON's 1,160,053 bytes. A nested update adds 891 native bytes versus 1,159,793 JSON bytes.

An excluded native baseline warmup measured 28.801 seconds for insert and 6.745 seconds for read. It is a single exploratory observation, not repeated comparative evidence.

Moving exact-fidelity checks outside timed reads improves comparability. The earlier `fair` stage still uses duplicate encoding validation and lacks decoded String sharing.

The optimized stage removes that extra validation pass and adds bounded String templates. Stage timings overlap, so these runs do not isolate each optimization's speed benefit.

The experiment does not establish an intrinsic speed limit for rb02. Further optimization would also need to address compaction and the complete Ruby value contract.

## Representation and scope

The encoder writes ordinary rb02 scalar payloads, shared field dictionaries, compact map records, and sixteen-slot array trees. Existing Ruby code reads and updates these records.

Encoding accepts arrays of flat hashes with identical ordered String keys. Each row has two through sixteen fields.

Values support nil, booleans, Fixnum integers, exact Float bits, and Strings up to 128 bytes. Keys are limited to 64 bytes.

The encoder rejects subclasses, singleton classes, Hash defaults, identity comparison, and mismatched schemas. Unsupported shapes use the original Ruby encoder through an experimental hook.

Decoding supports a subset of native records, with a depth limit of 32 and an array limit of one million elements. Unsupported records fall back.

The optimized encoder skips application-codec profiles. Earlier experimental revisions lack that guard. These hooks are measurement tools, not a production extension.

The prototype does not implement complete corruption validation, every scalar type, arbitrary codecs, general container encoding, or cross-platform packaging.

## Bounded byte traffic

The 10,000-row bulk encoder emits 1,106,326 bytes in seventeen append requests. Its largest request is 65,529 bytes.

The standalone traffic probe includes a 37-byte Core header placeholder. It excludes the logical root, history, transaction trailers, and public view dispatch.

A decoder without read buffers issues 80,686 requests totaling 1,730,499 bytes. Each request is at most 144 bytes.

The first cache assigned each file page to a fixed position. Shared early strings repeatedly displaced later row records, causing 143,418,771 requested bytes.

Replacing that policy with least-recently-used eviction reduces requests to nineteen, totaling 1,229,686 bytes. The cache retains at most eight 64 KiB pages.

These are logical read requests, not disk traffic. A newly fetched page temporarily exists alongside the retained pages during replacement.

The optimized decoder also retains at most 256 decoded String templates of at most 64 bytes. Returned String values remain independent and mutable.

That decoder requests 1,164,150 bytes in eighteen buffered reads. Without page buffers, its String cache reduces requests to 40,742, totaling 1,106,326 bytes.

## Measurement method

Workers run serially in fresh Ruby processes, reversing variant order between samples. Loading is separate, and each measured operation follows a full garbage collection.

The runtime is Ruby 4.0.9 on arm64 macOS. The extension uses installed Ruby headers and Apple clang, with no added gem dependency.

OS caches are not flushed. Local editing overlaps measurement runs. Timing varies substantially, so historical page timings are not a simultaneous comparison.

The original native benchmark includes key-order and String-encoding checks within native read timings. Its JSON branch times value equality alone.

The `fair` and `optimized` stages time value equality for both representations. Exact native checks still run outside the timed read sections.

Read the stage labels before comparing results. The `direct` and `lru` stages contain only completed warmups from interrupted exploratory matrices.

The archive contains 26 measured trials and 19 excluded warmups. The 58-record fixture and 1,000-record cases have one measured sample per store and variant.

Those smaller cases establish replay coverage, not stable performance rankings. The seven-sample production acceptance matrix remains outstanding.

The first matrix stopped after the cache amplified reads. The second stopped after baseline measurements exposed unequal validation costs inside timed reads.

Peak resident memory comes from `getrusage` and covers the complete worker, including verification and compaction. It is not a per-operation memory measurement.

The archived memory helper uses macOS byte units. Memory results from other operating systems require unit conversion and separate validation.

## Verification

The contract probe checks array-tree boundaries at 1, 16, 17, 255, 256, 257, 4,096, and 4,097 rows.

Eighteen scalar cases cover exact NaN bits, signed zero, infinities, invalid UTF-8, UTF-16LE, binary bytes, and non-default String encodings.

The decoder rejects all 148 truncated prefixes of the small recorded specimen. Five unsupported scalar inputs fail eligibility checks.

Public compatibility checks pair compiled encoding with Ruby decoding, Ruby encoding with compiled decoding, and both compiled paths. They verify updates, snapshots, rollback, and reopening.

Every timing worker verifies roundtrips, indexed reads, earlier snapshots, and compacted latest state. File workers also verify reopening. Compaction uses the unchanged Ruby implementation.

Archived workers use a fixed correctness label mentioning reopen, including memory runs. Replay removes that claim for memory; archived operation records identify the checks performed.

These checks establish the recorded prototype behaviors. They do not replace full production quality, malformed-data, concurrency, fault-recovery, or Linux memory gates.

## Replay

Run the optimized prototype against 10,000 records in a file:

```sh
ruby script/native_batch_replay.rb --stage optimized --output /tmp/native-batch.json
```

Use `--variant json` for the public JSON control. Use `--variant ruby` for the original native implementation.

The `encode`, `decode`, and `decode_cached` variants isolate the compiled encoder, unbuffered decoder, and buffered decoder. These variants also support further experiments.

Use `--store memory`, `--count 1000`, or `--count fixture` to change the input. Each output path must be unused.

Run the scalar, boundary, and compatibility checks:

```sh
ruby script/native_batch_replay.rb --stage optimized --check --output /tmp/native-batch-checks.json
```

Replay compiles the selected archived source and deletes its temporary directory afterward. It requires Ruby development headers and `make`.

[Sources](sources.json.gz) retain every measured revision, the Ruby library, and the exact input. The [manifest](provenance.json) records archive hashes.

[Summaries](summary.json.gz) retain sample counts, medians, ranges, allocations, byte sizes, and process memory. Raw per-stage matrices remain separate archives.

## Next step

Retain the bounded-I/O findings when integrating a bulk representation. Compare typed pages through public native views, including their larger update copies.

Production selection still requires complete scalar fidelity, general-value fallback, corruption checks, view mutation semantics, and measured compaction. The original performance goal remains active.
