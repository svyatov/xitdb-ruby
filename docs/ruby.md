# Ruby profile

`require "xitdb/ruby"` provides `XitDB::Ruby.open(path, readonly: false, lock_timeout: 5.0, codecs: [])` and `XitDB::Ruby.memory(codecs: [])`.
Configuration belongs to each handle. The file identifier `rb02` selects SHA-256 over canonical typed keys and compact native containers. Existing `rb01` files are incompatible; this pre-1.0 format has no migration or backward reader.

Small maps and sets store up to sixteen original keys directly in insertion order in a Core record. Map metadata is `1`, followed by alternating original-key and value slots; set metadata is `6`, followed by original-key slots. Keys must have distinct canonical identities, at most 128 canonical bytes and at most 256 encoded scalar bytes. Larger collections and oversized keys use the indexed envelope representation. Promotion preserves order and the first original key representation, and clearing an indexed collection retains that representation.

The Core record extension has tag `17`, an unsigned big-endian 32-bit metadata word, an unsigned big-endian 32-bit field count, and up to 32 consecutive nine-byte slots. Compaction follows all fields and preserves shared references. Pinned reference implementations do not support this extension. Portable containers retain their existing wire representation.
The [portable guide](portable.md) defines the shared transaction, snapshot, history, ownership, stream, and view contracts.

## Native values and keys

Supported exact builtin value classes include nil, booleans, Integer, Float, String, Symbol, Hash, Array, Set, Time, Date, DateTime, BigDecimal, and Rational.
Integers have arbitrary size. Strings preserve bytes and encoding names. Unknown encodings raise `UnsupportedEncodingError` on decoding.
Time preserves its exact rational instant, including subnanosecond fractions, UTC flag, and integer UTC offset.
The offset wire field is an integer: fractional-second UTC offsets raise `UnsupportedValueError`. Instant precision is unchanged.
Named timezone rules are not stored. Date and DateTime preserve their calendar start and date or instant.
BigDecimal preserves numeric value and signed zero. Rational preserves numerator and denominator.
Float values preserve IEEE representations, including infinities and NaN outside keys.

Ordinary keys and set members accept exact NilClass, TrueClass, FalseClass, Integer, Float, String, and Symbol instances.
Symbols and Strings remain distinct, as do Integer and Float keys. Float keys normalize signed zero and reject NaN.
ASCII-compatible String keys with equal ASCII bytes compare equally. Non-ASCII keys retain encoding-sensitive equality.
Ordinary keys never use custom codecs. Containers, temporal values, and custom objects cannot be ordinary keys.

Maps and sets preserve insertion order. Updating retains position; deleting and reinserting moves an entry to the end.
Native containers select the ordinary Ruby-profile representation. Counts are available without scanning members.
Hash defaults, default procs, identity comparison, singleton behavior, executable objects, and cyclic inputs are unsupported.
Scalar and container subclasses need an explicit value codec. Unregistered subclasses reject before overridden methods execute.

## Sorted collections

Declare `XitDB.sorted_map(key: :integer)` or `XitDB.sorted_set(key: :string)` explicitly.
Key kinds are `:string`, `:integer`, `:float`, and `:time`.
Strings use valid UTF-8 byte order. Integers include arbitrary-size values; Float rejects NaN.
Time keys compare exact rational instants, independent of presentation offset.
`rank`, inclusive `from`, `from_index`, and `page` use the storage tree. Snapshot pagination remains stable through later commits.

## Custom values

```ruby
Money = Struct.new(:cents)
codec = XitDB::Ruby::Codec.new(
  id: "example/money/v1", type: Money,
  dump: ->(money) { money.cents.to_s },
  load: ->(bytes) { Money.new(Integer(bytes)) }
)
XitDB::Ruby.memory(codecs: [codec]) do |db|
  db.transaction { |root| root[:price] = Money.new(125) }
  p db.snapshot[:price].cents # 125
end
```

Dumps return byte Strings. Use stable, schema-versioned identifiers. Duplicate IDs, overlapping registrations, and builtin overrides raise `CodecConfigurationError`.
Register subclass values explicitly; registering codecs never extends key support.
Loader input is a frozen copy. Return a fresh owned value for each call.
The profile freezes the returned object's outer state. The codec must control mutable references inside that object.
`to_ruby` invokes loaders independently. Unknown codecs return immutable `EncodedValue` objects that retain complete payload bytes.
Opening and unrelated traversal never load classes or run arbitrary object deserialization.

Callbacks can read transaction views. Coercion, dump, load, and conversion callbacks cannot start a second logical mutation during one Core transaction's active mutation.
The guard applies across Context instances; nested writes raise `TransactionStateError` before changing state.
Callback failure aborts the affected assignment. Byte-stream callbacks retain their separate non-overlapping sibling-write behavior.

See [native workflows](../examples/ruby.rb) and the [wire contract](ruby-profile-v1.md).
