# xitdb for Ruby implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. Preserve the execution method selected by the user.

**Goal:** Ship the compatible xitdb core, portable Ruby interface, and optional Ruby extension in one first release.

**Architecture:** One storage core implements upstream format and transaction behavior. Shared collection views delegate value representation to portable or Ruby profiles. The Ruby profile owns its encodings and ordered container envelopes.

**Tech Stack:** MRI Ruby, Ruby standard libraries, Minitest 6, Rake 13, and Bun for the TypeScript reference adapter.

**Spec:** [Approved design](../specs/2026-11-04-xitdb-ruby-design.md). The [Ruby wire contract](2026-11-04-ruby-profile-v1.md) fixes the encoding choices delegated to this plan.

## Global constraints

- The first release targets MRI Ruby 3.3 and later.
- It uses Ruby's standard libraries and shipped gems.
- The gem requires no compiler or additional runtime service.
- Configuration belongs to each database handle.
- Opening never upgrades a file or changes its profile.
- New portable files default to SHA-1 with header identifier `sha1`.
- The Ruby profile uses header identifier `rb01`.
- `lock_timeout:` defaults to five seconds.
- Integer and float keys remain distinct.
- Native Hash, Array, and Set inputs select their profile's ordinary collection representation.

The approved design supplies every other public behavior. Keep its unsupported-value limits and error classes intact.

Use Conventional Commits and the branch name `feat/xitdb-ruby`. Create isolation through the worktree skill when execution starts.

Use the installed Minitest 6.0.6 and Rake 13.4.2 for local development. Record their resolved versions in `Gemfile.lock` without upgrading unrelated tooling.

The [Minitest upstream](https://github.com/minitest/minitest) documents `minitest/autorun` and `minitest/test_task`. The [Rake upstream](https://github.com/ruby/rake) documents `rake`.

Native temporal and decimal codecs use the official [Date](https://github.com/ruby/date) and [BigDecimal](https://github.com/ruby/bigdecimal) libraries.

Request installation approval if required tools or gems are missing. Use their upstream installation instructions. Reference checkouts belong in an ignored temporary directory.

Each task stages only its listed files before committing. Each green verification command requires zero failures and zero errors.

`rake test` runs core, public, and Ruby-profile tests. Reference and stress suites have explicit commands and never turn missing tools into passing checks.

From Task 3, `rake verify XITDB_CASE=CASE` runs that suite and its Go reference case. Go interoperability accompanies each core feature.

## Review focus

- F1: Non-local block exits and callback failures must abort the correct operation without retrying application code. Tasks 3, 10, 12, and 19 own these tests.
- F2: Equal Ruby keys must survive different process hash seeds and string encodings. Tasks 15 and 17 own these tests.
- F3: Corrupt lengths, future versions, and mismatched profiles must leave input files unchanged. Tasks 1, 3, 10, and 15 own these tests.
- F4: Separate handles, interrupted commits, and concurrent close must not lose committed writes or deadlock. Tasks 3 and 13 own these tests.
- F5: Streaming, conversion, compaction, and opaque codecs must avoid materializing unrelated data or dropping unknown bytes. Tasks 14, 19, 20, 22, and 24 own these tests.

## File structure and dependency order

| Files | Responsibility | First task |
| --- | --- | --- |
| `lib/xitdb.rb`, `lib/xitdb/version.rb`, `lib/xitdb/errors.rb` | Portable entry point, package version, and errors | 1 |
| `lib/xitdb/core.rb`, `lib/xitdb/core/format.rb`, `lib/xitdb/core/crc64.rb` | Raw entry point and binary primitives | 1 |
| `lib/xitdb/core/memory_store.rb`, `lib/xitdb/core/file_store.rb` | Positional storage and buffering | 2 |
| `lib/xitdb/core/database.rb`, `lib/xitdb/core/transaction.rb`, `lib/xitdb/core/cursor.rb`, `lib/xitdb/core/bytes.rb` | Commit engine, cursor ownership, and byte values | 3 |
| `lib/xitdb/core/array_list.rb`, `lib/xitdb/core/hash_map.rb` | Radix arrays and the four hash collection kinds | 4, 5 |
| `lib/xitdb/core/b_tree.rb`, `lib/xitdb/core/linked_array_list.rb`, `lib/xitdb/core/sorted_map.rb` | Counted B-tree and ordered collections | 6, 8 |
| `lib/xitdb/profiles/portable.rb`, `lib/xitdb/declarations.rb`, `lib/xitdb/core/hasher.rb` | Portable representation, declarations, and hash configuration | 9 |
| `lib/xitdb/database.rb`, `lib/xitdb/snapshot.rb`, `lib/xitdb/history.rb`, `lib/xitdb/revision.rb`, `lib/xitdb/context.rb`, `lib/xitdb/value_walker.rb` | Public lifecycle, history, and logical value ownership | 10 |
| `lib/xitdb/views/base.rb`, `map.rb`, `array.rb`, `set.rb`, `sorted.rb`, `linked_array.rb` under `lib/xitdb/views/` | Lazy collection interfaces | 10, 11 |
| `lib/xitdb/streams.rb` | Block-scoped byte streams | 14 |
| `lib/xitdb/ruby.rb`, `wire.rb`, `scalars.rb`, `key_encoding.rb`, `containers.rb`, `ordered_keys.rb`, `codec.rb` under `lib/xitdb/ruby/` | Native entry point and Ruby representation | 15-19 |
| `lib/xitdb/profiles/ruby.rb` | Ruby representation behind the shared profile interface | 17 |
| `lib/xitdb/core/offset_map.rb`, `compaction.rb`, `replication.rb` under `lib/xitdb/core/` | Graph copying and replication | 20, 21 |
| `lib/xitdb/conversion.rb` | Incremental logical copying between profiles and files | 22 |
| `test/core/`, `test/public/`, `test/ruby/`, `test/interop/`, `test/stress/` | Behavioral tests at the corresponding interface | Respective tasks |
| `script/interop.rb`, `test/interop/go/main.go`, `test/interop/manifest.json` | Early Go compatibility checks and pinned reference identities | 3 |
| `script/stress.rb`, `script/benchmark.rb`, `script/ci.rb` | Bounded workloads, measurements, and CI | 24, 25 |

The core precedes L2. Ruby scalars precede L3 containers. Maintenance uses core references and never reimplements a profile's storage engine.

Test snippets show assertion bodies for the named test inside a `Minitest::Test` subclass. `test/test_helper.rb` supplies `with_core`, `with_file_db`, and `with_ruby_db` helpers.

`with_core` yields a core memory database. File helpers yield a public database and temporary path, then close and remove their own files.

Helper implementations may refer lazily to public methods added by later tasks. Product files must not contain placeholder implementations for later tasks.

## Binary and operational decisions

The upstream header is 20 bytes: magic `xit`, padding byte, version u16, hash size u16, hash identifier, and file identifier u64.

A slot is nine bytes: a tag byte followed by an unsigned 64-bit payload. The tag byte's high bit is `full`.

The root header starts at byte 20. It contains the root slot and committed file size, for a total of 17 bytes.

A trailer contains root slot, commit identifier u64, and CRC-64/XZ u64. It occupies 25 bytes. An initialized empty database occupies 62 bytes.

CRC input concatenates file identifier, trailer position, root slot, and commit identifier, all big-endian. Port the upstream checksum parameters exactly.

Use the approved reference SHAs. The source constants and reference fixtures decide every remaining physical layout, including counted headers and B-tree nodes.

Write buffers are bounded at 2 MiB. Byte streams copy in 64 KiB chunks. Offset caches spill after 16,384 entries.

Ordinary scalar lookup allocates that scalar. Parsing validates lengths against committed boundaries before allocation. Graph traversal uses an explicit stack.

Revision tokens retain file identity, a validated ancestor trailer position and checksum, and a history index. They remain usable across ordinary appends.

Resolving a token validates its ancestor trailer before reading that history entry. A restored or replaced file cannot reuse an invalidated trailer proof.

Revision tokens are opaque references, not globally canonical hashes of logical values. Distinct valid tokens may resolve the same history entry.

The internal profile interface is `encode(value, context:, path:)`, `decode(slot, context:, path:, immutable: true)`, `key_bytes(value)`, and `container(slot, context:, path:)`.

`encode` returns a core Slot. `decode` returns a scalar or view. `container` returns a profile-owned adapter used by shared views.

Each container adapter supplies `kind`, `size`, `lookup(selector)`, `assign(selector, slot)`, `delete(selector)`, and `each_entry`.

`lookup` returns a Slot or nil. `each_entry` yields Ruby selectors and Slots; the adapter decodes stored keys. Array and sorted adapters add their named positional operations.

`Context#mutate(path) { |cursor| ... }` stages one logical operation. Only successful completion replaces the context root and updates view generations.

`Context#read_bound` supplies the captured committed size or the active transaction's working limit. Every referenced object is validated against that bound.

Commit outcome is `:not_committed` before any root-header publication attempt. It is `:unknown` after publication starts but before confirmed header synchronization.

Outcome becomes `:committed` only after header synchronization succeeds. Reading a visible root after a failed sync cannot establish durability.

Portable mappings use byte-key identity. Bulk import and merge raise `KeyCollisionError` when distinct Ruby input keys collapse to one byte key.

## Tasks

### Task 1: Package load path and binary primitives

**Files:** Create `xitdb.gemspec`, `Gemfile`, `Gemfile.lock`, `Rakefile`, `.gitignore`, `LICENSE`, `lib/xitdb.rb`, `lib/xitdb/version.rb`, `lib/xitdb/errors.rb`, `lib/xitdb/core.rb`, `lib/xitdb/core/format.rb`, `lib/xitdb/core/crc64.rb`, `test/test_helper.rb`, and `test/core/format_test.rb`.

**Interfaces:** Produce `Core::Header.new(file_id:, hash_id:, hash_size:)`, `Header.parse(bytes)`, `Header#to_bytes`, `Core::Slot`, and `Core::CRC64.call(bytes)`.

Slots expose `tag`, `value`, `full`, `empty?`, and `to_bytes`. Factories are `Slot.parse(bytes)`, `.int(value)`, `.uint(value)`, `.float(value)`, and `.null`.

- [ ] **Step 1:** Add `test_header_and_null_vectors` and CRC vectors.

```ruby
header = XitDB::Core::Header.new(file_id: 1, hash_id: "sha1", hash_size: 20)
assert_equal "7869740000010014736861310000000000000001", header.to_bytes.unpack1("H*")
assert_equal "800000000000000000", XitDB::Core::Slot.new(tag: :none, value: 0, full: true).to_bytes.unpack1("H*")
assert_equal 0x330284772e652b05, XitDB::Core::CRC64.call("a")
```

- [ ] **Step 2:** Run `ruby -Ilib:test test/core/format_test.rb`. Expect failure from the missing library.
- [ ] **Step 3:** Implement the named primitives and package load path. Use version `0.1.0`, Ruby requirement `>= 3.3`, and upstream MIT notices. Define the complete design error hierarchy and immutable error paths.
- [ ] **Step 4:** Run `rake test`. Include malformed headers, unknown tags, wrong widths, and integer boundaries.
- [ ] **Step 5:** Commit as `feat(core): encode xitdb format primitives`.

### Task 2: Positional file and memory stores

**Files:** Create `lib/xitdb/core/memory_store.rb`, `lib/xitdb/core/file_store.rb`, and `test/core/store_test.rb`. Modify `lib/xitdb/core.rb`.

**Interfaces:** Produce `MemoryStore.new(bytes = "".b)` and `FileStore.open(path, readonly: false, buffer_limit: 2 * 1024 * 1024)`.

Stores implement `read_at(offset, length)`, `write_at(offset, bytes)`, `append(bytes)`, `length`, `truncate(length)`, `flush`, `sync`, `close`, `closed?`, and `readonly?`.

`append` returns its starting offset. A memory store is writable; file stores retain their opening mode.

- [ ] **Step 1:** Add `test_positional_reads_and_bounded_pending_writes` for both stores.

```ruby
store.write_at(0, "abcdef")
assert_equal "cd", store.read_at(2, 2)
assert_equal 6, store.append("gh")
assert_equal "abcdefgh", store.read_at(0, 8)
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/core/store_test.rb`. Expect missing store constants.
- [ ] **Step 3:** Implement complete positional reads and writes, short-write handling, and the 2 MiB pending buffer. Add `with_exclusive_lock(timeout:)`, process-local serialization, and read-only guards.
- [ ] **Step 4:** Run `bundle exec rake test`. Test partial syscalls, interrupted syscalls, reads spanning the buffer, and flush failures.
- [ ] **Step 5:** Commit as `feat(core): add positional storage backends`.

### Task 3: Raw transactions, scalar slots, and durable publication

**Files:** Create `lib/xitdb/core/database.rb`, `lib/xitdb/core/transaction.rb`, `lib/xitdb/core/cursor.rb`, `lib/xitdb/core/bytes.rb`, `test/core/database_test.rb`, `test/support/fault_store.rb`, `test/fixtures/core/empty-v1.hex`, `script/interop.rb`, `test/interop/go/main.go`, and `test/interop/manifest.json`. Modify `lib/xitdb/core.rb` and `Rakefile`.

**Interfaces:** Produce `Core::Database.open(path, readonly: false, hash_size: nil, hash_id: nil, file_id: nil, lock_timeout: 5.0)`.

Add `.memory(hash_size: 20, hash_id: "sha1", file_id: nil)`, `#root_cursor`, `#transaction { |cursor| ... }`, `#bytes(data, format_tag: nil)`, and `#committed_size`.

`#read_bytes(slot, bound: nil)` returns immutable `Core::ByteValue` with `bytes` and `format_tag`. Cursor children inherit their parent's read bound.

The constructor accepts `store:`, `hash_size: nil`, `hash_id: nil`, `file_id: nil`, and `lock_timeout: 5.0`. Tests inject the real store through a fault wrapper.

`Cursor#slot` returns a Slot; `#replace(slot)` changes its location. `#child(kind:, selector:)` resolves a child. `#transaction` returns its owning transaction or nil.

`Transaction#checkpoint`, `#restore(checkpoint)`, and `#freeze` support internal operation isolation. `Transaction#cursor(slot:)` creates a detached value cursor owned by that transaction.

`Transaction#cancel_publication` supports facade transactions with no mutations. It does not execute another callback or publish another trailer.

Create the Go adapter and `rake verify` for `empty` and `scalars` cases. Follow Task 23's request protocol and the modern-Go skill.

- [ ] **Step 1:** Add `test_empty_file_and_exception_rollback` and fault-point publication tests.

```ruby
assert_equal 62, core.committed_size
assert_raises(RuntimeError) { core.transaction { |cursor| cursor.replace(core.bytes("new")); raise "abort" } }
assert core.root_cursor.slot.empty?
assert_equal 62, core.committed_size
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/core/database_test.rb`. Expect missing database methods.
- [ ] **Step 3:** Implement trailer validation, first commit ID 0, scalar allocation, and synchronization ordering. Refresh committed state under the writer lock; discard only uncommitted tail bytes. Classify commit failures from observed publication and sync results.
- [ ] **Step 4:** Run `bundle exec rake verify XITDB_CASE=scalars`. Cover occupied null, tagged bytes, embedded zero bytes, short bytes, floats, bad checksums, truncated files, early exits, interrupts, and publication faults.
- [ ] **Step 5:** Commit as `feat(core): publish durable raw transactions`.

### Task 4: Persistent radix arrays

**Files:** Create `lib/xitdb/core/array_list.rb` and `test/core/array_list_test.rb`. Modify `lib/xitdb/core.rb`, `lib/xitdb/core/cursor.rb`, and `test/interop/go/main.go`.

**Interfaces:** Produce `Core::ArrayList.new(cursor)`, `#size`, `#get(index) -> Slot?`, `#cursor_at(index, create: false)`, `#append(slot)`, `#put(index, slot)`, `#truncate(size)`, and `#each -> Enumerator<Slot>`.

- [ ] **Step 1:** Add `test_radix_boundaries_and_shared_history` for lengths 0, 1, 15, 16, 17, 255, 256, and 257.

```ruby
assert_equal 257, list.size
assert_equal 256, list.get(-1).value
assert_nil list.get(257)
assert_equal 15, old_list.get(15).value
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/core/array_list_test.rb`. Expect the missing collection.
- [ ] **Step 3:** Port the upstream radix layout and copy-on-write traversal. Reacquire cursor paths after freeze boundaries.
- [ ] **Step 4:** Run `bundle exec rake verify XITDB_CASE=array-list`. Cover sparse occupied nulls, truncation, negative indexes, and reopened file arrays.
- [ ] **Step 5:** Commit as `feat(core): add persistent array lists`.

### Task 5: Hash maps, sets, and counted variants

**Files:** Create `lib/xitdb/core/hash_map.rb` and `test/core/hash_map_test.rb`. Modify `lib/xitdb/core.rb`, `lib/xitdb/core/cursor.rb`, and `test/interop/go/main.go`.

**Interfaces:** Produce `Core::HashMap.new(cursor, counted: false, set: false)`, `#get(hash_bytes)`, `#put(hash_bytes, key:, value:)`, `#remove(hash_bytes)`, `#cursor_at(hash_bytes, create: false)`, `#size`, and `#each_entry`. Expose named HashSet and counted constructors over the same implementation.

Add `#key(hash_bytes)` and `#include?(hash_bytes)` based on entry presence. Set constructors expose `#add(hash_bytes, key:)`, including entries whose value slot is empty.

- [ ] **Step 1:** Add `test_shared_hash_prefixes_and_exact_counts`, using raw hashes with 39 equal nibbles and distinct final nibbles.

```ruby
assert_equal 2, map.size
assert_equal 7, map.get(first_hash).value
assert map.remove(first_hash)
assert_equal 1, map.size
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/core/hash_map_test.rb`. Expect missing collection methods.
- [ ] **Step 3:** Port all trie branches, key/value records, removals, and counted headers. Enforce hash widths and preserve raw key slots.
- [ ] **Step 4:** Run `bundle exec rake verify XITDB_CASE=hash-collections`. Cover all four tags, missing versus occupied null, deep shared prefixes, key-only records, and immutable old roots.
- [ ] **Step 5:** Commit as `feat(core): add hash collections and counts`.

### Task 6: Counted B-tree insertion and rank access

**Files:** Create `lib/xitdb/core/b_tree.rb`, `lib/xitdb/core/linked_array_list.rb`, and `test/core/b_tree_test.rb`. Modify `lib/xitdb/core.rb` and `test/interop/go/main.go`.

**Interfaces:** Produce internal `Core::BTree#at(index)`, `#insert(index, slot)`, `#replace(index, slot)`, `#size`, and `#each_from_index(index)`. Produce `Core::LinkedArrayList.new(cursor)` with array reads and append.

- [ ] **Step 1:** Add `test_leaf_and_branch_splits_preserve_rank` through 4,097 entries.

```ruby
assert_equal 4097, tree.size
assert_equal 2048, tree.at(2048).value
assert_equal [4095, 4096], tree.each_from_index(4095).map(&:value)
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/core/b_tree_test.rb`. Expect missing B-tree methods.
- [ ] **Step 3:** Port upstream node headers, 16-slot leaves, branch counts, split rules, and count-guided descent.
- [ ] **Step 4:** Run `bundle exec rake verify XITDB_CASE=linked-array-insert`. Verify counts after every seeded insertion and compare file reads with a Ruby Array oracle.
- [ ] **Step 5:** Commit as `feat(core): add counted B-tree insertion`.

### Task 7: B-tree deletion, slicing, and concatenation

**Files:** Modify `lib/xitdb/core/b_tree.rb`, `lib/xitdb/core/linked_array_list.rb`, `test/core/b_tree_test.rb`, and `test/interop/go/main.go`. Create `test/core/linked_array_list_test.rb`.

**Interfaces:** Add `BTree#delete_at(index)`, `#split(index)`, and `#concat(other)`. Add `LinkedArrayList#slice(start, length)`, `#split(index)`, and `#concat(other)` with structural sharing.

These raw slicing operations return detached collection handles. Assign their Slots to persist them. Public view concatenation replaces its receiver through `Context#mutate`.

- [ ] **Step 1:** Add `test_split_concat_and_root_collapse` against a seeded array oracle.

```ruby
left, right = list.split(17)
assert_equal (0...17).to_a, left.each.map(&:value)
assert_equal (17...257).to_a, right.each.map(&:value)
assert_equal list.each.to_a, left.concat(right).each.to_a
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/core/linked_array_list_test.rb`. Expect missing split operations.
- [ ] **Step 3:** Port deletion balancing, root collapse, shared slices, and concatenation. Reject cross-database raw references.
- [ ] **Step 4:** Run `bundle exec rake verify XITDB_CASE=linked-array-edit`. Exercise first, middle, and final deletions across tree heights and empty operands.
- [ ] **Step 5:** Commit as `feat(core): support B-tree deletion and sharing`.

### Task 8: Raw sorted maps and sets

**Files:** Create `lib/xitdb/core/sorted_map.rb` and `test/core/sorted_map_test.rb`. Modify `lib/xitdb/core.rb`, `lib/xitdb/core/b_tree.rb`, and `test/interop/go/main.go`.

**Interfaces:** Produce `Core::SortedMap.new(cursor, set: false)`, `#get(key_bytes)`, `#put(key_bytes, value:)`, `#remove(key_bytes)`, `#rank(key_bytes)`, `#at(index)`, `#each_from(key_bytes)`, and `#each_from_index(index)`. Expose `Core::SortedSet`.

Add entry-based `#include?(key_bytes)` and set `#add(key_bytes)`. Empty value slots do not make existing set members absent.

- [ ] **Step 1:** Add `test_byte_order_rank_and_prefix_seek` with empty, zero-containing, ASCII, and non-ASCII keys.

```ruby
assert_equal 1, index.rank("b")
assert_equal ["b", "c"], index.each_from("b").map(&:first)
assert_equal "c", index.at(-1).first
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/core/sorted_map_test.rb`. Expect missing sorted collections.
- [ ] **Step 3:** Port sorted record variants and byte comparisons. Reuse B-tree counts for rank and pagination.
- [ ] **Step 4:** Run `bundle exec rake verify XITDB_CASE=sorted-collections`. Assert bounded reads for a seek near the end; verify key-only set records from reference fixtures.
- [ ] **Step 5:** Commit as `feat(core): add sorted maps and sets`.

### Task 9: Portable scalar codec and declarations

**Files:** Create `lib/xitdb/profiles/portable.rb`, `lib/xitdb/declarations.rb`, `lib/xitdb/core/hasher.rb`, and `test/public/portable_profile_test.rb`. Modify `lib/xitdb.rb` and `lib/xitdb/core.rb`.

**Interfaces:** Produce `Profiles::Portable.new(hasher: Core::Hasher.sha1)`, `#encode_scalar(value, core:)`, `#decode_scalar(slot, core:, bound: nil, immutable: true)`, and `#key_bytes(value)`.

Add `XitDB.uint(value)`, `.bytes(bytes, format_tag: nil)`, `.map(counted: false)`, `.set(counted: false)`, `.array`, `.linked_array`, `.sorted_map`, and `.sorted_set` as immutable declarations.

Produce immutable `Core::Hasher.new(id:, size:, &digest)` with `id`, `size`, and `digest(bytes)`. Builtins are `.sha1`, `.sha256`, `.sha384`, and `.sha512`.

- [ ] **Step 1:** Add `test_portable_types_and_strict_keys` at the profile interface.

```ruby
assert_raises(XitDB::UnsupportedValueError) { profile.key_bytes(:name) }
assert_equal "name".b, profile.key_bytes("name")
assert_equal :uint, encode(2**64 - 1).tag
assert_raises(RangeError) { encode(2**64) }
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/public/portable_profile_test.rb`. Expect the missing profile.
- [ ] **Step 3:** Implement strict scalar types, UTF-8 validation, opaque tagged bytes, and declarations for all eight core collections. Validate custom hash identifier and digest widths.
- [ ] **Step 4:** Run `bundle exec rake test`. Test booleans, Symbol values, invalid binary text, explicit unsigned values, declaration metadata, and immutable error paths.
- [ ] **Step 5:** Commit as `feat(api): encode portable Ruby values`.

### Task 10: Public transactions, maps, snapshots, and history

**Files:** Create `lib/xitdb/database.rb`, `lib/xitdb/snapshot.rb`, `lib/xitdb/history.rb`, `lib/xitdb/revision.rb`, `lib/xitdb/context.rb`, `lib/xitdb/value_walker.rb`, `lib/xitdb/views/base.rb`, `lib/xitdb/views/map.rb`, and `test/public/database_test.rb`. Modify `lib/xitdb.rb` and `lib/xitdb/profiles/portable.rb`.

**Interfaces:** Produce `XitDB.open(path, readonly: false, hash: nil, lock_timeout: 5.0)` and `.memory(hash: :sha1)`. `hash` accepts a builtin algorithm Symbol or `Core::Hasher`.

Database exposes `transaction`, `snapshot(revision: nil)`, `history`, `revert`, `close`, and `closed?`. Snapshot delegates map reads and exposes `revision`.

History exposes `[]`, `fetch`, `each`, and `size`. Complete the internal profile interface and `Context#view(slot, path:, kind:)`.

Map locations return map views. Other containers initially use Base's generic enumeration, size, and materialization; Task 11 adds their specialized methods.

Map views expose `[](key)`, `fetch(key, default = UNSET, &block)`, `dig(*keys)`, `key?`, `[]=(key, value)`, `delete(key, &block)`, `clear`, `merge!(hash)`, and the approved read methods.

- [ ] **Step 1:** Add `test_snapshot_history_revert_and_block_exits` using the approved profile example.

```ruby
db.transaction { |root| root["visits"] = 0 }
before = db.snapshot
after = db.transaction { |root| root["visits"] += 1 }
assert_equal [0, 1], [before["visits"], after["visits"]]
assert_equal 0, db.revert(before)["visits"]
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/public/database_test.rb`. Expect missing public entry points.
- [ ] **Step 3:** Implement iterative value walking, conventional history roots, and validated revision proofs. Resolve `sha1`/20 and `sha2`/32, 48, or 64; require explicit hashing for unknown identifiers. Handle virtual empty snapshots and no-op transactions.
- [ ] **Step 4:** Run `bundle exec rake test`. Test block exits, Hash defaults, readonly opening, foreign revisions, unknown profiles, stale proofs, missing files, and unchanged invalid inputs. Include UTF-8 and binary keys with equal bytes in one input Hash.
- [ ] **Step 5:** Commit as `feat(api): add transactions and immutable snapshots`.

### Task 11: Remaining lazy collection views

**Files:** Create `lib/xitdb/views/array.rb`, `lib/xitdb/views/set.rb`, `lib/xitdb/views/sorted.rb`, `lib/xitdb/views/linked_array.rb`, and `test/public/collections_test.rb`. Modify `lib/xitdb/profiles/portable.rb` and `lib/xitdb/views/base.rb`.

**Interfaces:** Produce the approved collection method matrix. Array reads accept integer indexes, ranges, and index-length slices. Slices are lazy read-only views; integer assignment supports gap filling. Add `LinkedArrayView#split(index)` and `#concat(other)`.

Sorted views expose `rank(key)`, `from(key)`, `from_index(index)`, and `page(offset:, limit:)`. Enumeration methods return Enumerator without a block.

- [ ] **Step 1:** Add `test_array_gaps_sets_and_sorted_pages` through public declarations.

```ruby
db.transaction { |root| root["items"] = []; root["items"][2] = "x" }
assert_equal [nil, nil, "x"], db.snapshot["items"].to_ruby
assert_equal "x", db.snapshot["items"][-1]
assert_kind_of Enumerator, db.snapshot["items"].each
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/public/collections_test.rb`. Expect missing view operations.
- [ ] **Step 3:** Implement the exact view matrix and Ruby argument semantics. Keep slice access incremental and document radix-array insertion and deletion costs.
- [ ] **Step 4:** Run `bundle exec rake test`. Compare seeded supported array operations with Ruby Array; test sets, efficient linked slices, rank pages, eager Enumerable outputs, and lazy child values.
- [ ] **Step 5:** Commit as `feat(api): expose lazy collection operations`.

### Task 12: Ownership, view validity, and operation rollback

**Files:** Modify `lib/xitdb/context.rb`, `lib/xitdb/value_walker.rb`, `lib/xitdb/views/base.rb`, and all collection views. Create `test/public/ownership_test.rb` and `test/public/iteration_test.rb`.

**Interfaces:** Complete `Context#mutate(path)`, view generation guards, `View#to_ruby`, logical equality, and bounded `inspect`. Use explicit traversal stacks and cycle tracking on active graph paths.

- [ ] **Step 1:** Add `test_assignment_captures_values_without_aliases` and `test_rescued_assignment_is_atomic`.

```ruby
db.transaction do |root|
  root["a"] = [1]
  root["b"] = root["a"]
  root["b"] << 2
  assert_equal [1], root["a"].to_ruby
end
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/public/ownership_test.rb`. Expect the unimplemented ownership guard to fail an assertion.
- [ ] **Step 3:** Freeze storage frontiers and reacquire raw paths around staged operations. Preserve live writable descendants during iteration; invalidate structural iterators and replaced child locations. Determine direct-reference compatibility from physical storage identity, not the header identifier alone.
- [ ] **Step 4:** Run `bundle exec rake test`. Test retained input mutation, frozen returned strings, cross-file views, expired views, thread ownership, cycles, deep trees, nested updates during iteration, and structural invalidation.
- [ ] **Step 5:** Commit as `feat(api): enforce value ownership and view lifetimes`.

### Task 13: Cross-thread and cross-process file behavior

**Files:** Modify `lib/xitdb/database.rb`, `lib/xitdb/core/database.rb`, and `lib/xitdb/core/file_store.rb`. Create `test/public/concurrency_test.rb` and `test/public/durability_test.rb`.

**Interfaces:** Complete active-operation tracking, `close` coordination, per-file nested-write detection, `BusyError`, and `CommitError#outcome`. Mark uncertain handles as requiring reopening.

- [ ] **Step 1:** Add `test_two_handles_refresh_after_lock` with two independent processes incrementing one committed counter.

```ruby
assert_equal 200, reopened.snapshot["counter"]
assert_equal 1, callback_invocations_on_success
assert_equal 0, callback_invocations_on_lock_timeout
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/public/concurrency_test.rb`. Expect the missing cross-handle coordination to fail.
- [ ] **Step 3:** Finish writer coordination and lifecycle guards. Use monotonic timeout measurement and independent read positions. Release read guards before yielding user iteration callbacks. Preserve the five-second default without making tests wait five seconds.
- [ ] **Step 4:** Run `bundle exec rake test`. Exercise concurrent close, snapshot reads during writes, nested handles for one inode, process interruption, both sync failures, and known versus uncertain commit outcomes.
- [ ] **Step 5:** Commit as `feat(storage): coordinate writers and commit recovery`.

### Task 14: Public byte streams

**Files:** Create `lib/xitdb/streams.rb` and `test/public/streams_test.rb`. Modify `lib/xitdb/core/bytes.rb` and `lib/xitdb/views/base.rb`.

**Interfaces:** Produce `View#open_bytes(key) { |reader| ... }` and `#write_bytes(key) { |writer| ... }`. Readers implement `read`, `readpartial`, `seek`, `rewind`, `pos`, `size`, and `eof?`; writers implement `write` and `pos`.

- [ ] **Step 1:** Add `test_io_copy_stream_and_writer_abort` with a source larger than the write buffer.

```ruby
db.transaction { |root| root.write_bytes("blob") { |io| IO.copy_stream(source, io) } }
db.snapshot.open_bytes("blob") { |io| assert_equal expected_digest, Digest::SHA256.hexdigest(io.read) }
assert_raises(XitDB::ExpiredViewError) { retained_reader.read(1) }
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/public/streams_test.rb`. Expect missing stream methods.
- [ ] **Step 3:** Implement 64 KiB copying, bounded source reads, automatic successful finalization, and discarded failed assignments. Reject overlapping mutations of an active stream value.
- [ ] **Step 4:** Run `bundle exec rake test`. Cover seek boundaries, short reads, EOF conventions, early exits, escaped handles, and the independent rollback of one failed stream assignment.
- [ ] **Step 5:** Commit as `feat(api): stream byte values through Ruby IO`.

### Task 15: Ruby scalar and hash-key encoding

**Files:** Create `lib/xitdb/ruby/wire.rb`, `lib/xitdb/ruby/scalars.rb`, `lib/xitdb/ruby/key_encoding.rb`, `test/ruby/test_helper.rb`, `test/ruby/wire_test.rb`, `test/ruby/scalars_test.rb`, `test/ruby/key_encoding_test.rb`, and `test/fixtures/ruby/v1/scalars.json`.

**Interfaces:** Produce `Ruby::Scalars.encode(value, core:, registry: nil) -> Core::Slot`, `.decode(slot, core:, bound: nil, registry: nil, immutable: true)`, and `Ruby::KeyEncoding.dump(value) -> frozen String`.

Produce shared `Ruby::Wire` helpers `u`, `b`, `t`, `z`, `q`, and `f64`. `Wire::Reader` parses their inverse fields and validates payload exhaustion.

Produce immutable `Ruby::EncodedValue` with `codec_id`, `format_tag`, and frozen `bytes` for custom payloads whose registry entry is absent.

The Ruby test helper supplies `key_bytes(value)` and `round_trip(value, immutable: true)` through these methods. Follow the complete wire contract.

- [ ] **Step 1:** Add `test_distinct_types_and_equal_encoded_strings` against literal golden bytes.

```ruby
assert_equal "03000101", key_bytes(1).unpack1("H*")
refute_equal key_bytes(1), key_bytes(1.0)
assert_equal key_bytes(""), key_bytes("".encode("UTF-16BE"))
assert_equal key_bytes("name"), key_bytes("name".b)
refute_equal key_bytes("é"), key_bytes("é".b)
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/ruby/key_encoding_test.rb`. Expect missing Ruby codecs.
- [ ] **Step 3:** Implement minimal scalar encodings, exact key canonicalization, frozen decoded scalars, and the `rb` payload parser. Keep code independent of collection views.
- [ ] **Step 4:** Run `bundle exec rake test`. Compare two fresh Ruby processes; test huge integers, all empty-string encodings, signed zero, NaN keys, unknown versions, malformed lengths, and unsupported encodings.
- [ ] **Step 5:** Commit as `feat(ruby): encode native scalars and typed keys`.

### Task 16: Exact temporal and decimal values

**Files:** Modify `lib/xitdb/ruby/scalars.rb`, `xitdb.gemspec`, and `Gemfile.lock`. Create `test/ruby/standard_values_test.rb`. Extend `test/fixtures/ruby/v1/scalars.json`.

**Interfaces:** Complete wire type codes `05` through `09` for Time, Date, DateTime, BigDecimal, and Rational. Declare the shipped `date` and `bigdecimal` gem dependencies needed by Bundler.

- [ ] **Step 1:** Add `test_exact_time_offset_and_decimal_zero` through scalar round trips.

```ruby
time = Time.at(Rational(1, 10**12)).getlocal(3600)
assert_equal time.to_r, round_trip(time).to_r
assert_equal 3600, round_trip(time).utc_offset
assert_equal BigDecimal("-0").sign, round_trip(BigDecimal("-0")).sign
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/ruby/standard_values_test.rb`. Expect unsupported scalar types.
- [ ] **Step 3:** Implement the exact instant, calendar, decimal, and rational fields from the wire contract. Use compatible versions of the official shipped gems without introducing another runtime library.
- [ ] **Step 4:** Run `bundle exec rake test`. Cover UTC versus zero offset, subnanosecond fractions, Gregorian and Julian starts, DateTime offsets, infinities, NaN values, and independent mutable materialization.
- [ ] **Step 5:** Commit as `feat(ruby): preserve exact standard Ruby values`.

### Task 17: Ordered Ruby containers and public entry point

**Files:** Create `lib/xitdb/ruby.rb`, `lib/xitdb/ruby/containers.rb`, `lib/xitdb/profiles/ruby.rb`, and `test/ruby/database_test.rb`. Modify `lib/xitdb/context.rb` and `lib/xitdb/views/base.rb`.

**Interfaces:** Produce `XitDB::Ruby.open(path, readonly: false, lock_timeout: 5.0, codecs: [])` and `.memory(codecs: [])`. Implement the shared profile interface using `rb01` headers and versioned envelopes.

- [ ] **Step 1:** Add `test_ordered_native_keys_and_profile_isolation` using the approved L3 example.

```ruby
db.transaction { |root| root[:name] = "symbol"; root["name"] = "string" }
assert_equal [:name, "name"], db.snapshot.keys
db.transaction { |root| root.delete(:name); root[:name] = "again" }
assert_equal ["name", :name], db.snapshot.keys
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/ruby/database_test.rb`. Expect the missing native entry point.
- [ ] **Step 3:** Implement exact array, linked-array, map, and set envelopes. Maintain lookup and order indexes atomically. Retain original equal keys on updates and preserve constant-time size.
- [ ] **Step 4:** Run `bundle exec rake test`. Test scalar keys, Set restrictions, Hash defaults, identity comparison, unknown profiles, insertion-ID overflow, isolation, native history, and cross-process lookup.
- [ ] **Step 5:** Commit as `feat(ruby): add ordered native collection profiles`.

### Task 18: Ruby sorted key kinds

**Files:** Create `lib/xitdb/ruby/ordered_keys.rb` and `test/ruby/sorted_test.rb`. Modify `lib/xitdb/ruby/containers.rb`, `lib/xitdb/declarations.rb`, `lib/xitdb/views/sorted.rb`, and `test/ruby/test_helper.rb`.

**Interfaces:** Add `XitDB.sorted_map(key:)` and `.sorted_set(key:)` for Ruby-profile declarations. Produce `Ruby::OrderedKeys.dump(value, kind:)` for `:string`, `:integer`, `:float`, and `:time`.

The test helper's `ordered(value, kind)` calls this encoder. Compare encoded strings with binary encoding.

- [ ] **Step 1:** Add `test_ordered_bytes_match_exact_numeric_and_time_order`.

```ruby
numbers = [-(2**200), -1, 0, 1, 2**200]
assert_equal numbers, numbers.shuffle.sort_by { |n| ordered(n, :integer) }
times = [Rational(-1, 3), 0, Rational(1, 10**12), Rational(1, 3)]
assert_equal times, times.shuffle.sort_by { |t| ordered(Time.at(t), :time) }
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/ruby/sorted_test.rb`. Expect unsupported key kinds.
- [ ] **Step 3:** Implement the exact prefix-free integer and rational encodings. Use iterative continued fractions for time keys. Retain original logical keys in sorted entry records.
- [ ] **Step 4:** Run `bundle exec rake test`. Cover prefix pairs, negative rationals, huge denominators, float infinities, normalized zero, invalid UTF-8, key-kind mismatches, rank, and stable snapshot pages.
- [ ] **Step 5:** Commit as `feat(ruby): add typed ordered indexes`.

### Task 19: Custom value codecs and opaque values

**Files:** Create `lib/xitdb/ruby/codec.rb` and `test/ruby/codec_test.rb`. Modify `lib/xitdb/ruby/scalars.rb` and `lib/xitdb/profiles/ruby.rb`.

**Interfaces:** Produce `Ruby::Codec.new(id:, type:, dump:, load:)`. Consume `Ruby::EncodedValue` from Task 15 for unknown custom payloads.

Produce immutable `Ruby::CodecRegistry.new(codecs)`, `#for_value(value)`, and `#for_id(id)` for scalar codec dispatch. Registries belong to individual handles.

Dispatch uses exact classes. Reject duplicate classes, duplicate identifiers, and exact builtin overrides. Registered container subclasses remain permitted.

- [ ] **Step 1:** Add `test_unknown_codec_preserves_bytes_without_loading_classes` and a failing dump callback.

```ruby
assert_equal "example/money/v1", unknown.codec_id
assert_equal original_bytes, unknown.bytes
assert_raises(XitDB::CodecConfigurationError) { open_with([money_codec, money_codec]) }
assert_equal previous_root, root_after_rescued_dump_failure
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/ruby/codec_test.rb`. Expect missing codec registration.
- [ ] **Step 3:** Implement exact-class dispatch, overlap rejection, opaque passthrough, and the loader ownership contract. Registered callbacks only interpret their own versioned identifiers.
- [ ] **Step 4:** Run `bundle exec rake test`. Cover builtin overrides, container subclasses, frozen payloads, fresh decoded objects, side effects called once, no implicit constant lookup, and codec failure rollback.
- [ ] **Step 5:** Commit as `feat(ruby): support scoped custom value codecs`.

### Task 20: Core compaction with bounded reference tracking

**Files:** Create `lib/xitdb/core/offset_map.rb`, `lib/xitdb/core/compaction.rb`, and `test/core/compaction_test.rb`. Modify `lib/xitdb/core/database.rb`, `lib/xitdb/database.rb`, and `test/interop/go/main.go`.

**Interfaces:** Produce `Core::Database#compact(to:)` and public `Database#compact(to:)`. OffsetMap implements `fetch`, `store`, and `close`, spilling after 16,384 entries to a temporary core database.

- [ ] **Step 1:** Add `test_compaction_preserves_cycles_tags_and_latest_history` for core and public profiles.

```ruby
compacted = db.compact(to: destination)
assert_equal 1, compacted.history.size
assert_equal db.snapshot.to_ruby, compacted.snapshot.to_ruby
assert_equal old_value, before["value"]
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/core/compaction_test.rb`. Expect missing compaction.
- [ ] **Step 3:** Implement upstream graph copying with an explicit work stack and reference fixups. Preserve sharing and cycles; publish only into an empty target with a new file identity.
- [ ] **Step 4:** Run `bundle exec rake verify XITDB_CASE=compaction`. Test both profiles, arbitrary raw roots, same-file targets, nonempty targets, spills, interrupted copies, source preservation, and cleanup.
- [ ] **Step 5:** Commit as `feat(storage): compact graphs with bounded memory`.

### Task 21: Replication and staged replacement

**Files:** Create `lib/xitdb/core/replication.rb` and `test/core/replication_test.rb`. Modify `lib/xitdb/core/database.rb` and `test/interop/go/main.go`.

**Interfaces:** Produce `#replica_state`, `#replication_start(state)`, `#read_committed(start, finish, io)`, and `#apply_replicated(start, io, length)`. Add `Core::Database.copy_replica(to:, source_io:, length:)` for staged full replacements.

- [ ] **Step 1:** Add `test_incremental_replication_and_diverged_history` with deterministic file identifiers and independent commit identifiers.

```ruby
assert_equal source.committed_size, replica.committed_size
assert_equal 0, source.replication_start(diverged.replica_state)
assert_equal last_good_state, interrupted.replica_state
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/core/replication_test.rb`. Expect missing replication methods.
- [ ] **Step 3:** Port prefix verification, trailer validation, incremental application, and failure cleanup. Stage full replacement separately; application code chooses when closed readers can reopen against it.
- [ ] **Step 4:** Run `bundle exec rake verify XITDB_CASE=replication`. Cover empty replicas, partial reads, wrong lengths, interrupted append, interrupted replacement, compaction generations, restored backups, and opaque Ruby bytes.
- [ ] **Step 5:** Commit as `feat(core): replicate committed database bytes`.

### Task 22: Incremental conversion and cross-file copying

**Files:** Create `lib/xitdb/conversion.rb` and `test/public/conversion_test.rb`. Modify `lib/xitdb/database.rb` and both profile implementations.

**Interfaces:** Produce `Database#convert(to:, profile:, history: :all, transform: nil)` and `Context#copy_from(view, at:, transform: nil)`. The transform receives keyword arguments `value:`, `path:`, and `role:`, where role is `:key` or `:value`.

- [ ] **Step 1:** Add `test_explicit_native_to_portable_transform_and_collision`.

```ruby
transform = ->(value:, path:, role:) { value.is_a?(Symbol) ? value.to_s : value }
assert_equal "Ada", native.convert(to: target, profile: :portable, transform: transform).snapshot["name"]
assert_raises(XitDB::KeyCollisionError) { conflicting.convert(to: other, profile: :portable, transform: transform) }
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/public/conversion_test.rb`. Expect missing conversion.
- [ ] **Step 3:** Implement iterative history copying, binary-string streaming, explicit unsupported-value callbacks, and atomic target publication. Capture the source history once. Disable logical-node reuse when a transform is provided, since it can depend on the path.
- [ ] **Step 4:** Run `bundle exec rake test`. Cover both directions, selected histories, foreign references, opaque tags, unknown codecs, path-dependent transforms, concurrent source writes, destination conflicts, and no whole-root materialization.
- [ ] **Step 5:** Commit as `feat(api): convert profiles without materializing roots`.

### Task 23: Four-language interoperability adapters

**Files:** Modify `script/interop.rb`, `test/interop/manifest.json`, and `test/interop/go/main.go`. Create `test/interop/reference_test.rb`, `test/interop/test_helper.rb`, `test/interop/typescript/main.ts`, `test/interop/java/Main.java`, and `test/interop/zig/main.zig`. Add generated reference fixtures under `test/fixtures/interop/`.

**Interfaces:** `ruby script/interop.rb --reference NAME --case CASE` checks one adapter. `--all` requires all four. Adapters accept JSON requests with operation, case, path, and hash fields; large numbers use decimal strings in the test protocol.

Operations are `write`, `read`, `compact`, and `replicate`. Test helpers expose `read_reference_fixture`, `assert_reference_reads_ruby_file`, and `assert_reference_compacts_and_replicates_ruby_file` with reference and case arguments.

- [ ] **Step 1:** Add `test_reference_files_round_trip_all_core_kinds` with separately generated files and fixture provenance.

```ruby
assert_equal expected_values, read_reference_fixture(reference, "all-kinds")
assert_reference_reads_ruby_file(reference, "all-kinds")
assert_reference_compacts_and_replicates_ruby_file(reference)
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/interop/reference_test.rb`. Expect missing independent reference fixtures.
- [ ] **Step 3:** Implement adapters against the four approved SHAs. Fetch through `gh` into temporary checkouts. Record toolchain versions and source hashes; use Bun for TypeScript. Apply the modern-Go skill when writing the Go adapter.
- [ ] **Step 4:** Run `ruby script/interop.rb --all`. Require all kinds, scalars, signedness, tags, history, compaction, and interrupted replication in both directions. Include opaque Ruby-profile compaction and replication. Report TypeScript Number precision separately; verify exact raw integer bits too.
- [ ] **Step 5:** Commit as `feat(interop): verify the four reference implementations`.

### Task 24: Memory budgets and measured performance

**Files:** Create `script/stress.rb`, `script/benchmark.rb`, `test/stress/memory_test.rb`, `test/stress/workload.rb`, and `docs/benchmarks.md`.

**Interfaces:** `ruby script/stress.rb --limit-mib 256 --data-mib 768` runs an isolated Linux process. `ruby script/benchmark.rb --output PATH` records workload parameters, Ruby version, elapsed distributions, allocations, and file sizes.

The stress workload uses file databases in both profiles. Memory-database benchmarks stay within the process budget.

- [ ] **Step 1:** Add `test_lookup_pagination_conversion_and_compaction_below_dataset_size` with a hard memory limit.

```ruby
assert_operator report.fetch("dataset_bytes"), :>, report.fetch("memory_limit_bytes")
assert_equal %w[lookup pagination stream conversion compaction], report.fetch("completed")
assert_operator report.fetch("offset_cache_peak_entries"), :<=, 16_384
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/stress/memory_test.rb`. Expect the missing isolated workload.
- [ ] **Step 3:** Implement deterministic data generation and measured runs using Ruby standard libraries. Separate memory and file results, and warm and cold runs. Record unavailable cache control explicitly.
- [ ] **Step 4:** Run `ruby script/stress.rb --limit-mib 256 --data-mib 768`. Require successful incremental operations in both profiles.
- [ ] **Step 5:** Run `ruby script/benchmark.rb --output pkg/benchmark.json`. Require the documented workload fields without asserting arbitrary timing thresholds.
- [ ] **Step 6:** Commit as `feat(benchmarks): verify bounded database workloads`.

### Task 25: Packaged examples, documentation, and CI gates

**Files:** Create `README.md`, `CHANGELOG.md`, `docs/portable.md`, `docs/ruby.md`, `docs/core.md`, `docs/ruby-profile-v1.md`, `examples/portable.rb`, `examples/ruby.rb`, `examples/indexed_users.rb`, `script/ci.rb`, `.github/workflows/ci.yml`, `test/support/package_helpers.rb`, and `test/public/package_test.rb`. Modify `xitdb.gemspec`, `Rakefile`, and `Gemfile.lock` as required by verified packaging.

**Interfaces:** `ruby script/ci.rb` runs fast tests, packaged examples, and gem-file inspection. CI requires separate interop and stress gates. Copy the completed wire contract to `docs/ruby-profile-v1.md`.

The package test helper's `packaged_example(name)` runs the named example and parses its JSON result. Runtime examples use only the installed package.

- [ ] **Step 1:** Add `test_built_gem_loads_both_profiles_in_a_clean_bundle` and executable examples for every approved workflow.

```ruby
assert_equal "Ada", packaged_example("portable").fetch("name")
assert_equal true, packaged_example("ruby").fetch("enabled")
assert_equal %w[Ada Grace], packaged_example("indexed_users").fetch("names")
```

- [ ] **Step 2:** Run `bundle exec ruby -Ilib:test test/public/package_test.rb`. Expect missing packaged examples.
- [ ] **Step 3:** Complete documentation, shipped-gem dependency metadata, and CI for MRI 3.3, 3.4, and 4.0 on Linux, plus file behavior on macOS. Vet CI actions and toolchains before pinning them. Preserve upstream license notices.
- [ ] **Step 4:** Run `ruby script/ci.rb`. Require successful tests, examples, and package inspection. Report remote CI results only after authorized execution; define separate required reference and Linux memory jobs.
- [ ] **Step 5:** Commit as `feat(package): document and verify both database profiles`.

## Source and environment notes

Reference revisions are copied from the approved design into `test/interop/manifest.json`. Toolchain versions and fixture hashes become part of each generated fixture's provenance.

The planning environment has Ruby 4.0.9, Minitest 6.0.6, Rake 13.4.2, Go 1.27.3, and Bun 1.4.4. Zig and Java are unavailable.

That inventory is evidence about this planning session. Executors recheck it before running commands. Missing reference tools cannot become a green interoperability result.

The [Zig source baseline](https://github.com/xit-vcs/xitdb/blob/6b93af1af3a260399fa0a0b1b268ded2cbf5eec5/src/lib.zig) defines the physical structures and publication sequence.

The [Go checksum tests](https://github.com/golang/go/blob/master/src/hash/crc64/crc64_test.go) supply the independent `a` checksum vector used in Task 1.

## Plan self-review

- Coverage: Tasks 1-8 implement L1 collections; 20 and 21 complete L1 maintenance. Tasks 9-14 implement L2. Tasks 15-19 implement L3.
- Ownership: Task 12 owns same-transaction sharing, per-operation rollback, view invalidation, iteration, cycles, and materialization.
- Compatibility: Task 23 exercises all four pinned references. Task 25 keeps those gates separate from local Ruby results.
- Resource behavior: Tasks 14, 20, 22, and 24 cover streaming and bounded traversal. Ordinary scalar allocation remains explicit.
- Boundaries: Runtime and dependency constraints are global. Signatures come from producer Interfaces blocks. No implementation task changes the approved profile contract.

Before execution, review this plan together with the approved design and wire contract. Select native or subagent-driven execution through the writing-plans handoff.
