# Changelog

## Unreleased

### Changed

- Core boolean readers are now `Slot#full?` and `Cursor#valid?`; the old names were removed.
- Validation and assertion helpers now use `!`, including `Core::Format.integer!` and `Core::Format.ensure_width!`.
- Substantial classes have dedicated files. Existing require entry points and on-disk encodings remain unchanged.
- The interoperability workflow uses Zig 0.17.1.

## 0.1.0 - 2026-11-05

Initial release of the `xitdb` gem. Requires MRI 3.3 or later.

### Added

- Pure Ruby storage for upstream xitdb maps, sets, counted collections, array lists, linked array lists, and sorted collections.
- Portable `sha1` and `sha2` files with the full signed and unsigned upstream integer ranges.
- Transactions with coordinated writers, lock timeouts, rollback, commit outcome reporting, and synchronized file publication.
- Stable snapshots, incremental collection views, history, revision tokens, and revert operations.
- Sorted range queries, rank lookup, and pagination through storage indexes.
- Byte streams with bounded transfers, compaction, and byte-preserving full and incremental replication.
- The `rb01` Ruby profile with typed keys, insertion-ordered maps and sets, and typed sorted indexes.
- Exact encodings for arbitrary-size integers, booleans, Symbols, String encodings, temporal values, BigDecimal, and Rational.
- Per-handle custom value codecs and immutable preservation of unknown encoded values.
- Explicit profile conversion and context-level copying between databases.
- RBS signatures, packaged examples, and guides for portable storage, Ruby values, the core API, and the Ruby wire format.
- Package installation tests, reciprocal checks against pinned Go, TypeScript, Java, and Zig references, and Linux memory workloads.

### Limitations

- Portable keys and set members must be Strings. Booleans, Symbols, and native temporal values require the Ruby profile.
- Conversion can duplicate data shared across histories, increasing runtime and output size. See [the measurements](docs/benchmarks.md).
- The public API can change before version 1.0.
