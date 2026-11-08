# Ruby profile version 3 wire contract

The header has hash size 32 and hash identifier `rb03`. Hash indexes use SHA-256 over canonical typed keys.

The page encoder, decoder, and storage adapters are implemented in Ruby. The gem has no compiled extension or build step.

Scalar encodings, key identity, indexed envelopes, and record metadata 1 through 6 retain the layouts specified in [version 2](ruby-profile-v2.md). Version 3 adds the page layouts below. Native handles reject `rb01` and `rb02` files without changing their contents. No migration or backward reader is provided.

## Page arrays

A Core record with metadata `7` has two fields: `[row_count:uint, pages:array_list]`. The count is positive. The page list has exactly `ceil(row_count / 1024)` entries. All descriptor full flags are clear.

Each page contains 1,024 rows, except the final page, whose length is the remaining count. A typed page uses an untagged `bytes` or `short_bytes` slot. A promoted page uses a packed array record with metadata `2` or `3` and the expected length. Page arrays cannot contain other page arrays as physical pages.

The encoder attempts this layout for exact Arrays with at least 32 rows. Every row must be an exact Hash with identical ordered String key representations. Hash defaults, identity comparison, singleton behavior, unsupported cells, and oversized pages cause general encoding to resume. Application callback exceptions propagate. Partial page writes are rolled back before fallback.

## Row references

A Core record with metadata `8` has three fields: `[page:bytes, row_index:uint, expected_rows:uint]`. The page field also accepts `short_bytes`. All descriptor full flags are clear.

The expected row count is between 1 and 1,024. The row index is less than that count. The payload count must match the descriptor. Compaction follows the page field and preserves shared references.

Transient row references retain only a page descriptor, index, and count. They contain no decoded values and cannot be serialized directly. Assigning one persists a metadata `8` record.

## Typed page payload

The complete payload is at most 65,536 bytes. It starts with ASCII `XP01`, then unsigned variable-length row and field counts. The row count is between 1 and 1,024. The field count is between 0 and 16.

Unsigned integers use least-significant seven-bit groups first. Bit 7 marks continuation. Encodings must be minimal and fit within 64 bits. The schema contains one encoded String per field. Row cells follow in row-major order, using that schema order.

| Tag | Value | Following bytes |
| --- | --- | --- |
| 0 | nil | None |
| 1 | false | None |
| 2 | true | None |
| 3 | Signed Integer | Zigzag-encoded unsigned variable-length integer |
| 4 | Float | Eight IEEE 754 binary64 bytes, most significant first |
| 5 | UTF-8 String | Variable-length byte count, then bytes |
| 6 | US-ASCII String | Variable-length byte count, then bytes |
| 7 | ASCII-8BIT String | Variable-length byte count, then bytes |
| 8 | Other String encoding | Encoding-name byte count, name, value byte count, then value bytes |

Tag `8` requires a canonical Ruby encoding name of 1 through 127 bytes. It cannot name the three encodings with dedicated tags. String bytes need not be valid in their declared encoding. Float payloads preserve every bit, including negative zero and NaN payloads.

Schema keys must be distinct under Ruby String key equality. Decoded keys are frozen. Decoded String values are independent and mutable when materialized. Larger Integers and unsupported scalar types use ordinary Ruby-profile storage.

Decoding rejects unknown tags, invalid counts, duplicate keys, noncanonical integers or encoding names, truncated payloads, and trailing bytes. Selected-row reads validate skipped cells without allocating their values. Stored descriptor errors raise `InvalidValueError`.

## Mutation and compatibility

A compatible replacement rewrites only its typed page and the required ancestor records. An incompatible replacement promotes that page to a packed array of persisted row references. Structural array changes promote the logical array to ordinary packed storage. Raw byte-stream writes preserve their untagged byte representation through promotion.

Portable storage remains unchanged. Pinned reference implementations cannot maintain native graphs that use the Core record extension. Loading the portable entry point does not load the Ruby page codec.
