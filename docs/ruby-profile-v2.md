# Ruby profile version 2 wire contract

This contract defines the `rb02` profile and the Core record extension to upstream format version 1.

## File identity

The header has hash size 32 and hash identifier `rb02`. Hash indexes use SHA-256 over the canonical key bytes defined below.

The `rb01` profile is incompatible. Native handles reject it without modifying the file. There is no backward reader or migration.

The physical root is an upstream array list of history entries. Each entry references an encoded logical root map.

Portable files retain their upstream header and layout. Pinned Go, TypeScript, Java, and Zig implementations do not support the record extension or native `rb02` containers.

Ruby scalar payloads retain version `01` and their literal wire bytes. References can preserve these opaque payloads inside portable Core graphs.

## Scalar notation

- W1: `U(n)` is minimal unsigned LEB128 for a nonnegative integer.
- W2: `B(bytes)` is `U(bytes.bytesize)` followed by those bytes.
- W3: `T(text)` is `B(text.encode("UTF-8"))`, with valid UTF-8 required.
- W4: `Z(n)` is one sign byte, then `B(magnitude)`. The sign is 0 for nonnegative and 1 for negative.
- W5: `Q(r)` is `Z(r.numerator)` followed by `U(r.denominator)`, with a positive, reduced denominator.

Integer magnitudes use minimal big-endian bytes. Zero has an empty magnitude and sign 0. A zero integer therefore has `Z(0) = 00 00`.

`F64(f)` is the eight bytes from Ruby's `pack("G")`. Multi-byte fixed integers use big-endian order.

Every field length must fit inside its enclosing byte payload. Nonminimal integers, truncated fields, invalid flags, and trailing bytes raise `InvalidValueError`.

## Encoded scalar values

Upstream byte values carry format tag `rb`, hexadecimal `72 62`. Their payload starts with version byte `01` and a type byte.

| Type byte | Ruby value | Remaining payload |
| --- | --- | --- |
| `01` | String | `T(encoding.name)`, `B(bytes)` |
| `02` | Symbol | `T(name.encoding.name)`, `B(name.bytes)` |
| `03` | Boolean | One byte, `00` for false or `01` for true |
| `04` | Large Integer | `Z(value)` |
| `05` | Time | `Q(value.to_r)`, `Z(value.utc_offset)`, one byte for `utc?` |
| `06` | Date | `Z(value.jd)`, `F64(value.start)` |
| `07` | DateTime | `Q(value.ajd)`, `Q(value.offset)`, `F64(value.start)` |
| `08` | BigDecimal | Decimal encoding defined below |
| `09` | Rational | `Q(value)` |
| `0a` | Registered custom value | `T(codec_id)`, `B(codec_bytes)` |

Integers fitting a native upstream integer slot use that slot. Signed 64-bit values use `int`; remaining unsigned 64-bit values use `uint`.

Values outside those ranges use type `04`. Floats use upstream float slots. Stored null uses an occupied upstream `none` slot.

Time decoding uses the exact rational instant and recorded UTC offset. The UTC flag distinguishes UTC presentation from a fixed zero offset.

The instant retains subnanosecond precision. The offset field accepts integer seconds only; fractional-second UTC offsets raise `UnsupportedValueError`.

Date and DateTime decoding restores the recorded calendar start. Their date fields use the public `date` library constructors.

Untagged byte values represent explicit binary data. Ruby reads them as frozen ASCII-8BIT strings. Public byte streams address these untagged values.

Other format tags remain opaque tagged-byte values. An unknown custom codec retains its complete encoded payload and codec identifier.

An unsupported Ruby payload version or builtin type raises `UnsupportedEncodingError`. A registered custom loader never runs during file opening or unrelated traversal.

### Decimal encoding

The first decimal byte is 0 for finite, 1 for positive infinity, 2 for negative infinity, or 3 for NaN.

Infinite and NaN encodings end after that byte. A finite value adds one sign byte, `T(digits)`, and `Z(exponent)`.

Sign 0 is positive; sign 1 is negative. Digits and exponent come from `BigDecimal#split`, whose base must be 10.

Digits contain normalized ASCII decimal digits. Zero uses digits `0` and exponent 0. Its sign preserves positive or negative zero.

## Canonical hash keys

These bytes determine key equality and hashing. The stored entry separately retains the original encoded key for enumeration.

| Prefix | Accepted key | Remaining canonical bytes |
| --- | --- | --- |
| `00` | nil | None |
| `01` | false | None |
| `02` | true | None |
| `03` | Integer | `Z(value)` |
| `04` | Float | `F64(value)`, with signed zero normalized to positive zero |
| `05` | String | Canonical string body defined below |
| `06` | Symbol | Canonical string body for `value.to_s` |

NaN keys raise `UnsupportedValueError`. Infinite float keys are accepted in hash indexes.

A canonical string body is `T(encoding_label)` followed by `B(bytes)`. The encoding label is empty for every empty string.

For nonempty ASCII-only strings with an ASCII-compatible encoding, the label is also empty. Other strings use their canonical `Encoding#name`.

This preserves Ruby's empty-string equality across encodings. It also preserves the distinction between non-ASCII binary and UTF-8 strings.

String and Symbol prefixes remain distinct. Integer and Float prefixes remain distinct.

Golden vectors include:

| Input | Hexadecimal canonical bytes |
| --- | --- |
| nil | `00` |
| false | `01` |
| true | `02` |
| 0 | `03 00 00` |
| 1 | `03 00 01 01` |
| -1 | `03 01 01 01` |
| Empty String in any encoding | `05 00 00` |
| ASCII String `name` | `05 00 04 6e 61 6d 65` |
| Symbol `name` | `06 00 04 6e 61 6d 65` |

The decoder does not reconstruct keys from canonical bytes. Entry records retain their original Ruby representation.

## Compact containers

Core tag `17` (`0x11`) identifies an external record. Its slot value is the record offset, and native container descriptors require a clear full flag.

The record starts with two unsigned big-endian 32-bit words: metadata and field count. The count is at most 32.

Consecutive nine-byte slots follow the header. Readers validate the count before reading fields and enforce their captured read boundary.

| Metadata | Logical type | Fields |
| --- | --- | --- |
| `1` | Literal map | Alternating original-key and value slots, at most sixteen pairs |
| `2` | Small Array | At most sixteen element slots |
| `3` | Tree Array | Exactly one upstream array-list slot |
| `4` | Dictionary map | One dictionary record slot, followed by two to sixteen value slots |
| `5` | Key dictionary | Two to sixteen original-key slots |
| `6` | Set | At most sixteen original-key slots |

Metadata `5` is an internal dictionary, not a logical collection. A dictionary descriptor requires a clear full flag and metadata `5`.

A dictionary map has exactly one value per dictionary key. Keys appear in insertion order in literal maps, dictionaries, and sets.

Every key has a supported exact scalar class and a distinct canonical identity. NaN keys are invalid.

Packed keys have at most 128 canonical bytes and 256 encoded scalar bytes. Readers check byte payload bounds before decoding keys.

Replacing an equal key retains its original slot and position. Deletion removes its position; reinsertion appends it.

The seventeenth map or set member, or an oversized key, promotes the collection to indexed storage. Clearing retains indexed storage.

Small arrays retain element slots directly. Tree arrays use sixteen slots per branch, with selective copy-on-write updates through the affected path.

Scalar payloads remain separate byte records. A large value therefore does not require decoding or copying its containing collection.

Compaction follows all record fields, remaps offsets, and preserves shared references. Unknown native metadata or invalid shapes raise `InvalidValueError`.

### Bounded sharing

One encoding operation can share 256 String or Symbol scalar slots with at most 64 source bytes each.

Scalar identity includes exact type, String encoding, and binary bytes. A separate object-identity cache recognizes 256 validated frozen String keys.

The operation can share 64 ordered dictionaries identified by their original encoded key slots. Additional shapes use literal maps.

Value-only updates can retain their dictionary. Key changes can publish a literal map without allocating another dictionary.

Read-only materialization caches 64 decoded dictionaries within that call. Transaction reads use no decoded dictionary cache.

Sharing creates no Ruby object aliases during materialization. Tables do not survive an operation or transaction rollback.

## Indexed container envelopes

Each envelope is an upstream array list with the exact fields shown below. Marker fields are upstream unsigned integer slots.

Encoded children can be scalar slots, scalar bytes, compact records, or indexed envelopes. Internal indexes use upstream containers.

| Marker | Logical type | Envelope fields |
| --- | --- | --- |
| `0x52420101` | Array | `[marker, array_list]` |
| `0x52420102` | Linked array | `[marker, linked_array_list]` |
| `0x52420103` | Ordered map | `[marker, next_id, lookup, order]` |
| `0x52420104` | Ordered set | `[marker, next_id, lookup, order]` |
| `0x52420105` | Sorted map | `[marker, key_kind, sorted_map]` |
| `0x52420106` | Sorted set | `[marker, key_kind, sorted_map]` |

Arrays and linked arrays contain encoded children. Their envelopes do not require materializing those children.

Unexpected markers, field counts, or physical collection kinds raise `InvalidValueError`. The core remains able to inspect the physical values.

### Indexed maps and sets

`next_id` is an upstream unsigned integer starting at zero. `lookup` is a counted upstream hash map. `order` is an upstream sorted map.

A lookup entry uses `SHA256(canonical_key_bytes)` as its hash. Its physical key is the canonical byte string.

Its physical value is a three-element upstream array list: `[encoded_key, encoded_value, insertion_id]`. Sets store occupied null as `encoded_value`.

An order entry maps the eight-byte big-endian insertion identifier to the 32-byte lookup hash. Both indexes reference the same logical entry.

Insertion creates one entry and increments `next_id`. Updating an equal key retains its original encoded key and insertion identifier.

Deletion removes both index entries. Reinsertion receives a fresh identifier. Clearing resets both indexes and `next_id`.

When `next_id` equals `2**64 - 1`, another insertion raises `RangeError`. Updates and deletions remain valid.

The logical size comes from the counted lookup map. Iteration follows the order index and resolves its referenced entries.

### Sorted maps and sets

Key kind is 1 for String, 2 for Integer, 3 for Float, or 4 for Time.

A sorted map stores order-preserving key bytes and a two-element record: `[encoded_original_key, encoded_value]`.

A sorted set also uses an upstream sorted map. Its value is the encoded original member. This retains representation beyond the comparison key.

Updating an equal comparison key retains its original encoded key or member. Every operation uses the declared key kind.

## Ordered key encoding

Ordered encodings use unsigned byte comparison. They contain no locale-dependent data and do not use Ruby's randomized hash.

### Integers

For nonnegative `n`, define `O(n)` as an eight-byte magnitude length followed by minimal big-endian magnitude bytes.

`O(0)` has length zero and no magnitude bytes. The length field is an unsigned 64-bit integer.

Ordered signed integers use prefix `00` for negative, `01` for zero, and `02` for positive.

Negative values append the bytewise complement of `O(abs(n))`. Positive values append `O(n)`. Zero ends after its prefix.

These encodings are prefix-free and compare in numeric order. Magnitude lengths exceeding the physical file range raise `RangeError`.

### Floats

Reject NaN. Normalize either signed zero to positive zero. Read the IEEE-754 bits as an unsigned 64-bit integer.

For negative values, complement all 64 bits. For nonnegative values, toggle the sign bit. Write the resulting eight bytes big-endian.

This places negative infinity first and positive infinity last. It gives either zero representation one lookup key.

### Strings

String keys must convert to valid UTF-8. Their ordered bytes are the resulting UTF-8 bytes without a length prefix.

The entry record retains the original encoding and bytes. Invalid or unconvertible keys raise `UnsupportedEncodingError`.

This comparison deliberately uses UTF-8 text order. Ordinary Ruby hash-key encoding retains its separate equality contract.

### Exact time instants

Time keys compare `value.to_r`, including fractions smaller than a nanosecond. Their comparison ignores presentation offsets.

For nonnegative rational `x`, define a prefix-free encoding `R(x)`:

1. Compute `q, remainder = x.numerator.divmod(x.denominator)`.
2. Write `O(q)`.
3. For zero remainder, append byte `00` and stop.
4. Otherwise, append byte `01` and the complement of `R(x.denominator / remainder)`.

The division in step 4 denotes an exact Rational. An iterative continued-fraction implementation avoids Ruby stack growth.

For signed rational instants, use the signed prefixes from integer encoding. Negative instants append the complement of `R(abs(x))`.

Positive instants append `R(x)`. Zero ends after its prefix. Prefix-free child encodings make byte complementation reverse their order.

This requires work proportional to the continued-fraction representation. It does not emit one byte per denominator unit.

## Ownership and loader behavior

View reads return frozen scalar values. Materialization creates independent values and mutable containers and strings where Ruby permits mutation.

Custom loaders receive a frozen copy of their payload. They must return a fresh owned value, without shared mutable state between calls.

The profile freezes the returned object's outer state for view reads. A custom codec owns the immutability of references inside that value.

Materialization invokes the loader independently. No implicit constant lookup or arbitrary object loader interprets stored class names.

## Required fixtures

Golden scalar fixtures retain their version-one payload notation. Regression tests cover compact records, dictionaries, indexed envelopes, key equality, signed zero, and unknown codecs.

Ordered-key fixtures compare encoded byte order with numeric or temporal order. They include negative values, huge integers, infinities, and exact subnanosecond instants.

Malformed fixtures cover truncated lengths, nonminimal integers, invalid encodings, invalid fields, and conflicting index records.

Changes to canonical keys, payload interpretation, or container layouts require a different profile identifier. Readers never infer a profile version from data shape.
