# Built-in input capture measurements

O1 reduces insert CPU time by 22 to 50 times against commit `57222b2` across all six groups.
It remains slower than Core JSON in all 30 median CPU comparisons.
Updates at 1,000 and 10,000 rows use 9% to 19% more CPU than the baseline.
These results support exploring bulk encoding and direct row offsets next.

## Scope and method

Production commit `6d26b1d` reads exact Array, Hash, and String contents through bound built-in methods.
Extended scalar and application codec validation retains the strict input guard.
The benchmark compares this commit, baseline `57222b2`, and direct Core JSON using identical generated records.
Each record contains three Strings, an Integer, and two nil values.

The run used Ruby 4.0.9, JSON 3.1.0, and arm64 macOS on November 13, 2026.
It started at 11:19:38 UTC and finished at 11:22:37 UTC.
Each group has two excluded warmups and twelve measured observations per variant.
All six execution orders rotate evenly across measured samples.
Each observation runs in a fresh process, with startup and explicit GC excluded from operation timings.
No other project runtime checks or benchmarks ran during measurement.

Workers verify insertion, full and selected reads, updates, snapshots, compaction, and file reopening.
The driver checks Ruby source provenance and rejects source changes during measurement.
The summarizer checks all 252 observations, dataset identity, sample indices, operation coverage, and stable storage sizes.
Stored sizes match the baseline exactly.

## CPU comparisons

Ratios are medians of paired CPU measurements: O1 divided by the named control.
A ratio below 1 uses less CPU.
Selected reads fetch three rows: first, middle, and last.

| Rows | Store | Control | Insert | Full read | Selected read | Update | Compact |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 58 | File | Baseline | 0.045 | 0.849 | 0.935 | 0.803 | 0.980 |
| 58 | Memory | Baseline | 0.035 | 0.837 | 0.911 | 0.749 | 0.987 |
| 1,000 | File | Baseline | 0.024 | 0.976 | 0.977 | 1.089 | 0.961 |
| 1,000 | Memory | Baseline | 0.023 | 0.973 | 0.986 | 1.101 | 0.993 |
| 10,000 | File | Baseline | 0.020 | 0.986 | 0.974 | 1.154 | 1.022 |
| 10,000 | Memory | Baseline | 0.020 | 0.998 | 0.978 | 1.189 | 0.976 |
| 58 | File | Core JSON | 2.674 | 4.283 | 9.874 | 4.542 | 1.436 |
| 58 | Memory | Core JSON | 3.981 | 4.257 | 9.740 | 7.209 | 1.338 |
| 1,000 | File | Core JSON | 14.981 | 5.892 | 22.097 | 18.486 | 1.454 |
| 1,000 | Memory | Core JSON | 22.361 | 6.032 | 23.329 | 24.010 | 1.366 |
| 10,000 | File | Core JSON | 31.036 | 6.510 | 2.713 | 3.218 | 1.079 |
| 10,000 | Memory | Core JSON | 37.233 | 6.674 | 2.826 | 3.235 | 1.230 |

Insert allocations fall to 21% to 28% of the baseline.
Update allocations increase by 16% to 38%, consistent with additional copies and bound method calls during page re-encoding.
That explanation is an inference from the implementation, not a separate allocation profile.
The unchanged read path shows little improvement at larger sizes.
Full medians, ranges, elapsed time, allocations, win counts, and storage bytes are retained in the archives.

## Reproduce

1. Create separate checkouts of production `6d26b1d` and baseline `57222b2`.
2. Extract the harness into a temporary directory with this Ruby script:

```ruby
require "json"
require "zlib"
require "fileutils"

archive, destination = ARGV
FileUtils.mkdir_p(destination)
sources = JSON.parse(Zlib::GzipReader.open(archive, &:read))
sources.each { |name, source| File.write(File.join(destination, name), source) }
```

3. From the production checkout, run the driver and summarizer with fresh output paths:

```sh
bundle exec ruby /tmp/harness/input_benchmark.rb /path/to/production /path/to/baseline /tmp/samples.json
bundle exec ruby /tmp/harness/summarize_input.rb /tmp/samples.json /tmp/summary.json
```

The harness uses only Ruby and the standard library.
Core JSON uses the installed JSON implementation as the comparison control.
The production codec has no compiled extension; Ruby's built-in methods remain available.

## Evidence and limits

`samples.json.gz` contains raw observations, runtime details, source hashes, correctness coverage, and harness hashes.
`summary.json.gz` contains absolute measurements and paired comparisons.
`harness.json.gz` contains the four exact measured scripts.
`provenance.json` identifies commits and archive checksums.

The production change passed `bundle exec rake`: 540 tests, 42,601 assertions, 100% typed calls, and CRAP threshold 10.
Independent public API QA covered hostile inputs, exact values, fallback, codecs, snapshots, rollback, and owned error paths.
These measurements cover one host and one generated dataset.
They establish neither cross-platform performance nor parity with Core JSON.
