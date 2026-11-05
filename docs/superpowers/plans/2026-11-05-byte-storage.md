# Byte storage implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Core::Bytes` the shared implementation of physical byte values without changing supported behavior.

**Architecture:** Add a captured byte source and one bounded writer inside `Core::Bytes`. Retain compatibility wrappers, then migrate streaming, conversion, and compaction callers. Profile interpretation and transaction publication remain separate.

**Tech Stack:** MRI Ruby 3.3+, standard libraries, Minitest, existing memory/file/fault adapters.

**Spec:** [Byte storage consolidation](../specs/2026-11-05-byte-storage-design.md).

## Global constraints

- Preserve existing supported interfaces, upstream format version 1, and the `rb01` representation.
- Preserve scalar inline selection, external conversion records, and compaction record representation.
- Keep bounded transfers at 65,536 bytes and file write buffers at 2 MiB.
- Keep MRI Ruby 3.3 and later, existing dependencies, and caller-owned resources.
- Change neither transaction publication nor directory synchronization.
- Add no supported application interface or general transfer framework.

## Review focus

- R1: A short automatic candidate containing NUL bytes must not invoke its source block twice. Task 1 tests reuse.
- R2: Progressing short IO reads must remain accepted by `Bytes.copy`. Task 1 characterizes compatibility.
- R3: A tagged record ending at the captured bound must include its complete tag. Task 1 tests exact extents.
- R4: Empty and short converted payloads must remain external records. Task 2 tests both profiles.
- R5: Shared external records must remain shared through compaction. Task 3 retains alias tests and adds short external records.

## Problem

`Core::Database#bytes/read_bytes`, `Core::Bytes`, and `Conversion::ByteSource` share physical layout knowledge.
`Streams::Reader` also branches on a String-or-offset result.
This Information Leakage increases cognitive load when validating ranges or changing transfer rules.
The design consolidates that concept rather than combining logical conversion with storage publication.

## Proposed interface

```ruby
Core::Bytes.open(database, slot, bound:) # => private Source
source.size
source.format_tag
source.read(position, length)
Core::Bytes.append(transaction, size:, format_tag: nil, prefix: "".b,
                   representation: :automatic) { |position, length| ... } # => Slot
```

For a converted logical slice, the caller supplies relative payload positions:

```ruby
Core::Bytes.append(transaction, size: selected_size, prefix: prefix,
                   format_tag: tag, representation: :external) do |position, length|
  source.read(selected_start + position, length)
end
```

The interface hides physical offsets, length headers, inline packing, tag placement, and chunking.
The spec defines argument, failure, ownership, and representation contracts.

## Cohesion statement

Single responsibility: represent byte values in physical storage.

- Owns physical decoding, range validation, inline selection, and bounded appending.
- Keeps profile encoding and logical traversal outside because they interpret values rather than store their bytes.
- Keeps view lifetime, IO position, graph identity, and publication outside with their existing owners.

## Dependency strategy

Category 2, local-substitutable: use the real core with `MemoryStore`, `FileStore`, and `FaultStore`.
Preserve those adapters and their synchronization rules.
No additional port or mock storage interface is needed.

## Testing strategy

Create `test/core/bytes_test.rb` for the shared interface and retained `locate/copy` behavior.
Keep the scalar, stream, conversion, and compaction suites as distinct behavioral tests.
Their checks cover freezing, encoding, expiry, rollback, sharing, and codec opacity beyond physical byte storage.
No existing tests are scheduled for removal.

Use initial RED for missing core operations.
Consumer migration is a refactor: record initial GREEN where characterization tests already pass.
Do not remove working behavior to manufacture RED.

Run focused suites after each task.
Run the full final matrix only after all three tasks, unless a failure requires an affected check to repeat.
Preserve reports outside temporary data trees and record the tested commit.

## Migration strategy

Use an incremental internal migration with compatibility wrappers.
Task 1 provides the shared implementation while keeping all consumer signatures.
Task 2 migrates streaming and logical conversion together.
Task 3 migrates physical byte copying during compaction, then runs final gates.
Implementation uses an isolated worktree; the earlier main-checkout audit and measurement records remain intact.

## File responsibilities

| File | Responsibility after migration |
| --- | --- |
| `lib/xitdb/core/bytes.rb` | Physical byte source, writer, and legacy locate/copy wrappers |
| `lib/xitdb/core/database.rb` | Scalar facades with their existing ownership and transaction checks |
| `lib/xitdb/streams.rb` | Block-scoped IO behavior using a captured source |
| `lib/xitdb/conversion.rb` | Logical ranges, profile helpers, and conversion traversal |
| `lib/xitdb/core/compaction.rb` | Graph copying and offset-map reuse through the byte seam |
| `test/core/bytes_test.rb` | Shared byte-interface and compatibility behavior |
| `test/public/streams_test.rb`, `test/public/conversion_test.rb` | Consumer behavior and physical-policy characterization |
| `test/core/compaction_test.rb` | Preserved representation, aliases, and bounded physical copying |
| `docs/core.md` | Explain the internal byte ownership without adding supported application methods |

## Implementation steps

### Task 1: Establish shared byte storage

**Files:** Modify `lib/xitdb/core/bytes.rb:5-36` and `lib/xitdb/core/database.rb:228-265`. Create `test/core/bytes_test.rb`.

**Interfaces:** Consumes `Database#read_at`, `Database#check_open!`, `Transaction#append`, and `Transaction#check_active!`. Produces the exact `Bytes.open`, source readers, and `Bytes.append` interface above.

**Estimated scope:** About 100-160 lines of shared implementation plus focused tests; move physical logic out of scalar facades.

- [ ] **Step 1: Characterize retained facades before replacing them.** Test existing scalar boundaries, `locate` result shapes, and progressing short IO reads. Keep `copy`'s small-input behavior compatible.
- [ ] **Step 2: Add missing-operation tests in `test/core/bytes_test.rb`.** Include this assertion inside a real core transaction:

```ruby
calls = []
slot = Core::Bytes.append(root.transaction, size: 3) do |position, length|
  calls << [position, length]
  "a\0b".b.byteslice(position, length)
end
assert_equal :bytes, slot.tag
assert_equal [[0, 3]], calls
assert_equal "a\0b".b, Core::Bytes.open(core, slot, bound: root.transaction.length).read(0, 3)
```

Also assert eight untagged bytes and six tagged bytes can be inline; seven tagged bytes remain external.
Test external empty records, end-position zero reads, wrong argument types, invalid ranges, tag boundaries, and a captured old bound.
Assert no payload read exceeds 65,536 bytes during copying, including a prefix exceeding one chunk.
Test nil, short, oversized, and non-String block results with the spec's error classes.
Inject a source error after one chunk and verify identical exception identity plus transaction rollback.
Verify repeated source reads do not re-read length or tag metadata.

- [ ] **Step 3: Run `ruby -Ilib:test test/core/bytes_test.rb`.** New-operation tests fail because `Bytes.open` or `Bytes.append` is absent; characterization tests pass.
- [ ] **Step 4: Implement the shared interface in `core/bytes.rb`.** Keep the source type private and reuse one private physical parser. Validate complete tagged extents before exposing metadata.
- [ ] **Step 5: Migrate scalar facades and compatibility wrappers.** `Database#bytes` retains `ByteValue` input capture and automatic representation. `read_bytes` materializes a source into `ByteValue`. Preserve `locate`'s rejection message and return shape. Buffer progressing short IO reads for the writer without changing `copy`'s small-value branch.
- [ ] **Step 6: Run `ruby -Ilib:test test/core/bytes_test.rb` and `ruby -Ilib:test test/core/database_test.rb`.** Expect zero failures, errors, and skips.
- [ ] **Step 7: Commit as `refactor(core): centralize physical byte storage`.** Stage only the two runtime files and their tests.

### Task 2: Migrate streaming and logical conversion

**Files:** Modify `lib/xitdb/streams.rb:34-66`, `lib/xitdb/conversion.rb:99-183`, `test/public/streams_test.rb`, and `test/public/conversion_test.rb`.

**Interfaces:** Consumes Task 1's `Bytes.open`, source readers, and `Bytes.append`. Preserves `Conversion::ByteSource#size/#format_tag/#read/#unsigned/#slice/#portable_encoding/#write_to` and public IO behavior.

**Estimated scope:** Replace approximately 50-80 lines of physical logic with delegation and logical range offsets.

- [ ] **Step 1: Add `test_short_and_empty_conversion_values_retain_external_representation`.** Cover empty bytes, `"abc"`, and opaque `"x"` tagged `"zz"` through portable-to-portable, portable-to-Ruby-to-portable, and Ruby-to-Ruby conversion. Assert external slot tags where conversion already uses them and unchanged logical values/tags.
- [ ] **Step 2: Run `ruby -Ilib:test test/public/conversion_test.rb` and `ruby -Ilib:test test/public/streams_test.rb`.** Record initial GREEN for these characterization tests.
- [ ] **Step 3: Replace Reader's inline/offset branch with a captured source.** Keep untagged-only validation, context guards, EOF behavior, seeking, and output-buffer ownership unchanged.
- [ ] **Step 4: Delegate ByteSource physical access to Task 1.** Retain logical start/length for slices. Keep unsigned parsing and encoding classification outside Core. Use `:external` in `write_to`, with the existing prefix/tag choices.
- [ ] **Step 5: Run both focused suites again.** Verify chunk bounds, malformed Ruby fields, source-relative transforms, stream expiry, closed handles, nonlocal exits, and sibling-write rollback remain covered and passing.
- [ ] **Step 6: Commit as `refactor(values): use shared byte storage for streams and conversion`.** Stage only migrated files and consumer tests.

### Task 3: Migrate compaction and verify the final implementation

**Files:** Modify `lib/xitdb/core/compaction.rb:69-86`, `test/core/compaction_test.rb`, and `docs/core.md`.

**Interfaces:** Consumes Task 1's captured source and writer with `representation: :external`. Preserves `Compaction#copy` and `OffsetMap#fetch/#store` behavior.

**Estimated scope:** Replace byte-record copying only, with approximately 15-30 runtime lines and representation characterization.

- [ ] **Step 1: Add a compaction characterization for a tagged three-byte external record.** Construct the raw record `[3].pack("Q>") + "abczz"`, reference it with a full `:bytes` slot, and compact it. Assert the copied slot remains `:bytes`, its payload is `"abc"`, and its tag is `"zz"`. Retain existing shared-offset, opaque-codec, and large-byte tests.
- [ ] **Step 2: Run `ruby -Ilib:test test/core/compaction_test.rb`.** Record initial GREEN for the new characterization.
- [ ] **Step 3: Replace physical byte transfer with the shared interface.** Retain offset-cache lookup/store order and return the copied external offset. Leave inline remapping, graph traversal, and all non-byte records unchanged.
- [ ] **Step 4: Update `docs/core.md` with the single physical byte owner.** Explain that scalar materialization and bounded transfer use that implementation. Keep internal operations outside the supported application-method documentation.
- [ ] **Step 5: Run `ruby -Ilib:test test/core/bytes_test.rb` and `ruby -Ilib:test test/core/compaction_test.rb`.** Expect zero failures, errors, and skips. Run `git diff --check` and the repository prose checker on changed documentation.
- [ ] **Step 6: Commit as `refactor(core): share byte storage with compaction`.** Stage only Task 3 files.
- [ ] **Step 7: Run `ruby script/ci.rb` once with each installed MRI 3.3, 3.4, and 4.0 runtime.** Use the selected runtime's executable. Expect zero failures, errors, and skips, plus packaged-example and gem-inspection success.
- [ ] **Step 8: Run `ruby script/interop.rb --all` on the final commit.** Use the existing pinned source trees and toolchains. Expect reciprocal reference checks to pass without blessing changed fixtures.
- [ ] **Step 9: Run `ruby -Ilib:test test/stress/memory_test.rb` with `XITDB_STRESS_REPORT` unset.** This must execute a fresh 256 MiB limit with a 768 MiB payload, both profiles, no swap, and no OOM. Preserve actual reports and all final logs. Do not substitute a saved report for a fresh result.

If a required runtime, reference tool, or cached container is unavailable, report that limitation without installing replacements or claiming a pass.
Repeat a gate only for changed code, a failure, or a specific unresolved concern.

## Handoff

This plan fits one implementation session with three independently reviewable tasks.
Retain the user's earlier subagent-driven execution preference, subject to review of this plan.
Use `$implement` with this plan after review.
Runtime implementation is outside the architecture-design skill.
