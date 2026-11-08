# Native pages implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Integrate the measured typed-page representation into the Ruby profile, preserving its value and transaction contracts, then measure against Core JSON.

**Architecture:** A bounded C codec handles exact flat rows behind three methods. Ruby adapters retain the existing core transaction, snapshot, reference, compaction, and fallback mechanisms. Unsupported shapes continue through the iterative value walker.

**Tech Stack:** Ruby >= 3.3, Ruby C extension built with standard-library mkmf, existing core storage. No new gem dependencies.

**Spec:** The user's ongoing performance goal and authorization to change representation, format, and API without migration support. The archived measured candidate is `docs/benchmarks/native-encode/sources.json.gz`. This plan records implementation choices, not additional user requirements.

**User amendment, 2026-11-08:** "don't use C, it must be ruby only". This supersedes the C codec and installation choices below. Remove the compiled extension, retain the bounded page contract in Ruby, verify correctness and packaging, and remeasure all six cases. Earlier C measurements are historical evidence only.

## Global constraints

- Keep exact Ruby values, Float bits, string encodings, key identity and insertion order.
- Preserve snapshots, transaction view lifetimes, rollback, writer coordination and durability. No decoded value cache may survive an operation or rollback.
- Bound each page to 65,536 bytes, 1,024 rows, and 16 fields. Unsupported or oversized inputs use general storage without recursive traversal.
- Build the extension at gem installation. Keep portable storage independent of the extension at runtime. No new dependencies.
- Activate pages under a new Ruby profile identifier, rb03. Do not change rb02 interpretation.
- Run `bundle exec rake`, installed-package checks, independent QA and a fresh source review. No push, PR, merge or release.

## Review focus

- Invalid lengths, varints, encoding names, duplicate schema keys, truncated or trailing bytes must fail with InvalidValueError before unbounded work.
- Rejected inputs and application callbacks must not be mistaken for successful page encoding or lose exceptions.
- Selected reads must validate all stored cells without allocating unrelated rows; descriptor counts must agree with payload counts.
- Captured transaction references must not survive rollback or expiration through a cached row.
- Build and installation must use the running Ruby ABI, work outside the checkout, and not require development gems.

### Task 1: Validated native codec and package build

**Files:** Create `ext/xitdb/page_codec/{extconf.rb,page_codec.c}`, `test/ruby/page_codec_test.rb`; modify `Rakefile`, `.gitignore`, `xitdb.gemspec`, `lib/xitdb/ruby.rb`, `sig/ruby.rbs`, package test and installation documentation.

**Interfaces:** Produces private `XitDB::Ruby::PageCodec.encode_page(input) -> String?`, `decode_page(bytes, expected_rows = nil) -> Array[Hash]`, `decode_row(bytes, index, expected_rows = nil) -> Hash`. Encoding returns nil for unsupported shape, does not swallow application exceptions, and does not mutate input. Decoding raises InvalidValueError for malformed data, IndexError for invalid row selection. Input types are checked without conversion callbacks. Wire magic XP01 is internal and versioned.

- [x] Write tests for exact scalar/encoding round trips, bounds, fallback, callbacks, malformed bytes, selected-row validation and expected counts. Run `bundle exec ruby -Ilib:test test/ruby/page_codec_test.rb`. Expected: missing native codec failure.
- [x] Adapt measured codec, replacing normal fallback exceptions with nil and validating all decoding paths. Add mkmf build and gem packaging, RBS declarations and documentation of compiler requirement.
- [x] Run `bundle exec rake` and independent native-code checks. Expected: all checks pass and installed examples load both profiles.
- [x] Commit codec and packaging as one independently testable increment. The storage format remains rb02 until Task 2.

### Task 2: Page storage and references

**Files:** Create `lib/xitdb/ruby/{pages,page_array,page_row,page_reference,page_cell}.rb` and focused public/format regression tests; modify profile, value walker, adapter assignment paths, signatures, and format documentation.

**Interfaces:** Consumes Task 1 codec. Produces rb03 records with metadata 7 for page arrays and 8 for persisted row references, plus operation-local transient cells and references. Metadata 7 fields are `[row_count:uint, page_list:array_list]`. Metadata 8 fields are `[page:bytes, row_index:uint, expected_page_rows:uint]`. All descriptor full flags must be clear. A page is an untagged byte value; a promoted page must be a packed array record with metadata 2 or 3 and the expected bounded size. Persist transient descriptors before core serialization. Materialize flat adapters through an explicit internal hook; keep iterative fallback for mixed/deep trees.

`Pages.encode(input, context:, path:) -> Core::Slot?` attempts only exact Arrays of at least 32 rows. Validate the outer array before invoking its iteration, then feed groups of at most 1,024 rows to the codec. Own one transaction checkpoint, restore it on unsupported pages, and release it in ensure. Never update PackingState caches during this attempt. General encoding resumes with the same active-ancestor stack after fallback.

`PageReference < Core::Slot` retains only the immutable byte descriptor, row index and expected count. It never retains a decoded row. `PageCell < Core::Slot` holds one decoded scalar for the current adapter operation; persist it with the profile scalar encoder before it reaches core serialization. Both refuse `to_bytes` until persisted. `Pages.persist(slot, context) -> Core::Slot` performs this conversion at Ruby adapter assignment/insertion and view assignment.

`PageRow` decodes lazily on the first value operation, so creating a view does not decode the same row twice. Its private row memo belongs to one adapter, not a retained view or context. Mutation promotes that row to a PackedMap; the PageArray ancestor can then rewrite a compatible typed page. `PageArray#materialize_flat` returns nil for mixed pages, which sends the entire collection through the existing iterative walker. `PageRow#materialize_flat` returns fresh mutable values and frozen keys; no source object escapes.

- [x] Write public tests for 32/1,024/1,025/2,050-row insertion, selected and full reads, scalar and row updates, promotion after key addition/nested replacement, slices/concat, copy/conversion, compaction, rollback after partial encode, snapshot/view lifetime, malformed descriptors, deep and oversized inputs. Verify byte growth for one compatible update remains within one page plus tree/record overhead. Run focused tests. Expected: pages not enabled or new format absent.
- [x] Integrate without prepend patches. Page arrays validate page counts and page lengths when accessed. Generic promoted pages must be array records with bounded counts, never recursive page arrays. Flat updates rewrite one page; shape-changing edits promote only the affected page where possible.
- [x] Run focused tests and `bundle exec rake`. Expected: all checks pass, including package examples and static type coverage.
- [x] Commit production integration and format documentation.

### Task 3: Independent verification and performance decision

**Files:** Archive reproducible integrated benchmarks under `docs/benchmarks/`; keep QA scripts in temporary storage.

**Interfaces:** Consumes installed production profile and existing Core JSON benchmark baseline. Reports CPU, elapsed time, bytes, correctness, and runtime/platform limits separately.

- [x] Run independent QA through the public API and a fresh source review; fix important findings with reproducing tests.
- [ ] Run fresh balanced comparisons for file and memory stores at small, medium and large sizes, including insert, read, indexed read, update and compaction. Check every output and store size.
- [ ] Record remaining misses against Core JSON. Continue performance work if the user's target remains unmet; do not mark the overall goal complete merely because integration passed.
