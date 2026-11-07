# rb01 comparison samples

These historical samples compare baseline `89f714d` with compatible optimizations at `fde9a5d`.
The run stopped at the user's request before experiments with a compact representation.
It contains 245 completed samples, including 213 measured samples and 32 excluded warmups.
The interrupted worker contributes no completed sample.

The fixture and 1,000-record cases have seven measured pairs for every layout and store.
The 10,000-record memory cases also have seven measured pairs.
The 10,000-record native file case has one complete pair and one additional candidate sample.
Its portable and JSON file cases did not run.

The compatible changes reduce intermediate writes and memory-store buffer copies.
They preserve the compacted representation and its retained size.
The compact-representation investigation uses these measurements as historical comparisons, with their actual sample counts.

Read the gzip files with `Zlib::GzipReader` or a gzip utility.

| Artifact | Contents |
| --- | --- |
| `rb01-historical-samples.json.gz` | Completed raw samples, fixture hashes, runtime, and library hashes |
| `rb01-construction-read-samples.json.gz` | Earlier construction and read comparison, stopped before the memory-store fix |
| `rb01-profiles.json.gz` | CPU, allocations, byte ledgers, checkpoint counts, and memory-copy controls |
| `rb01-provenance.json` | Revisions, completion counts, and artifact hashes |

Earlier staged workers inherited Bundler activation metadata.
Their incremental library-load samples are excluded from conclusions.
The historical comparison at `fde9a5d` restores an unbundled environment and rejects preloaded XitDB modules.
