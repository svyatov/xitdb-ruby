# Learn xitdb

xitdb stores collections in a file. A collection holds related values: a map connects keys to values, an array uses numbered positions, and a set holds unique members.

Start with the public API. Read the storage core after you can create a database, change values, and read snapshots.

## Store your first value

```ruby
require "xitdb"

XitDB.memory do |db|
  db.transaction do |root|
    root["user"] = { "name" => "Ada", "visits" => 1 }
  end

  puts db.snapshot.dig("user", "name") # Ada
end
```

`memory` keeps the database in this process. To keep data after the process ends, use `XitDB.open("users.xit")` with the same block.

The block form closes the database automatically. Without a block, keep the returned handle and call `close` yourself.

## Understand the root and views

The root is the top-level map. In the example, `"user"` is a root key, and its value is another map.

Reading a nested collection returns a view. A view reads stored entries when you request them. It does not load the entire collection.

Call `to_ruby` when you need ordinary Ruby containers that remain usable after the database closes:

```ruby
require "xitdb"

data = XitDB.memory do |db|
  db.transaction { |root| root["names"] = ["Ada", "Lin"] }
  db.snapshot.to_ruby
end

puts data["names"].first # Ada
```

`to_ruby` reads every nested entry. Its memory cost grows with the complete result. Normal views let you read selected entries.

## Change values in a transaction

A transaction groups related changes. Normal block completion commits them together. An exception aborts them.

```ruby
require "xitdb"

XitDB.memory do |db|
  db.transaction { |root| root["visits"] = 1 }

  begin
    db.transaction do |root|
      root["visits"] = 2
      raise "cancel this change"
    end
  rescue RuntimeError
    puts db.snapshot["visits"] # 1
  end
end
```

The writable root and its nested views belong to that transaction. They expire when its block ends. Read the returned snapshot for committed values.

Writers wait for a lock, which gives one writer access at a time. A lock timeout raises `BusyError` before the transaction block runs.

A commit error needs different handling. Read `CommitError#outcome` before deciding whether to retry. `:committed` means publication succeeded, and `:unknown` means the result could not be established.

An automatic retry can repeat application effects. See [locking and durability](https://github.com/svyatov/xitdb-ruby/blob/main/docs/core.md#locking-and-durability) for the full contract.

## Keep a previous state

A snapshot captures a committed root. Later transactions do not change its values.

```ruby
require "xitdb"

XitDB.memory do |db|
  db.transaction { |root| root["score"] = 10 }
  before = db.snapshot
  db.transaction { |root| root["score"] = 20 }

  puts before["score"]      # 10
  puts db.snapshot["score"] # 20

  db.revert(before)
  puts db.snapshot["score"] # 10
  puts db.history.size      # 3
end
```

`revert` adds a commit containing the selected previous state. It preserves the commits already in history.

Snapshots remain usable until their database handle closes. A revision is a token that identifies a history entry and checks its file generation.

An array range returns a captured, read-only slice. Use the original writable array view to change entries.

## Choose how values are represented

A profile defines which values and keys a file supports. It also defines how stored bytes become Ruby values.

| Profile | Entry point | Use it for |
| --- | --- | --- |
| Portable | `require "xitdb"`, `XitDB.open` | String keys and values supported by upstream implementations |
| Ruby | `require "xitdb/ruby"`, `XitDB::Ruby.open` | Symbol keys, booleans, large integers, dates, and other Ruby values |

```ruby
require "xitdb/ruby"

XitDB::Ruby.memory do |db|
  db.transaction do |root|
    root[:enabled] = true
    root[:large] = 2**200
  end
  puts db.snapshot[:enabled] # true
end
```

Opening a file does not change its profile. Use `Database#convert` to copy values into a different profile.

A codec converts an application object to a supported payload and converts that payload back. Register matching codecs when reading custom values.

The [Ruby guide](https://github.com/svyatov/xitdb-ruby/blob/main/docs/ruby.md) explains codec registration and the supported value types. The [portable guide](https://github.com/svyatov/xitdb-ruby/blob/main/docs/portable.md) lists portable values and limits.

## Choose a collection

Ordinary Ruby Hashes and Arrays are enough for many assignments. Collection declarations select a specific storage layout for an empty collection.

```ruby
require "xitdb"

XitDB.memory do |db|
  db.transaction do |root|
    root["users"] = XitDB.map(counted: true)
    root["users"]["ada"] = { "name" => "Ada" }
    root["scores"] = XitDB.sorted_map
    root["scores"]["ada"] = 10
  end
  p db.snapshot["scores"].page(offset: 0, limit: 5).to_a
end
```

| Collection | Meaning | Relevant API |
| --- | --- | --- |
| Map | Each unique key selects a value | `Views::Map` |
| Array | Each position selects a value | `Views::Array` |
| Linked array | An array backed by a tree for positional changes | `Views::LinkedArray` |
| Set | Each member appears once | `Views::Set` |
| Sorted map or set | Iteration follows the declared key order | `Views::Sorted` |

A counted hash collection stores its size with the structure. An uncounted hash collection can need traversal to calculate size.

Ruby-profile ordinary maps and sets preserve insertion order. Portable hash iteration follows storage order. Sorted collections follow their key ordering rules.

Adding or removing members during iteration raises `ConcurrentModificationError`. Replacing a collection can expire views of that location and its descendants.

## Understand the storage core

The public API turns Ruby values into stored structures through three layers:

1. A view provides map, array, or set operations at a logical path.
2. A profile encodes values and selects the correct collection adapter.
3. The core reads and writes slots, collection nodes, and commit records.

A slot is a small stored value descriptor. Its tag identifies the value kind. Its payload holds a small value or a reference to other bytes.

An offset is a byte position in storage. A bound is the exclusive end position that a captured reader may access.

A cursor carries a slot, its database, and its readable bound. A transaction cursor can replace its slot as structures change.

Committed structures are immutable. Changing a collection creates changed structure while keeping previous committed versions readable. Unchanged parts can share stored references.

A hash map uses a hash digest to locate a key through a tree. A sorted tree uses key comparisons to visit entries in order.

A trailer records a published root and its integrity information. A checksum detects changes to the checked bytes; it does not authenticate an untrusted file.

Compaction copies reachable structures to a separate file. Profile conversion reads logical values and encodes them again, which can duplicate shared data across history.

Replication transfers storage under the core's compatibility checks. It does not reinterpret values or convert profiles.

The [core guide](https://github.com/svyatov/xitdb-ruby/blob/main/docs/core.md) explains the file format, locking, durability, compaction, and replication.

## Find the implementation

| Path | Responsibility |
| --- | --- |
| `lib/xitdb/database.rb` | Public handle, transactions, snapshots, and maintenance |
| `lib/xitdb/views/` | Collection methods used by applications |
| `lib/xitdb/context.rb` | View lifetime, location checks, and logical mutations |
| `lib/xitdb/profiles/` | Portable and Ruby value interpretation |
| `lib/xitdb/ruby/` | Ruby scalars, keys, codecs, and container representation |
| `lib/xitdb/core/` | Storage, binary format, trees, commits, and replication |
| `lib/xitdb/value_walker.rb` | Nested value encoding and conversion to Ruby containers |
| `lib/xitdb/conversion.rb` | Copying logical values across contexts and profiles |
| `examples/` | Runnable application workflows |
| `test/` | Behavior checks and fault-injection helpers |
| `script/` | Development checks, measurements, and reference implementation checks |

Internal helpers use `@api private` where appropriate. They explain implementation details without promising a stable application API.

## Build the API reference

With YARD available in your development environment, run `yard doc` from the repository root. Open `doc/index.html` to read the result.

`.yardopts` selects library source and includes this guide. Run `yard stats --list-undoc` to inspect documentation coverage.

YARD is optional and is not a runtime dependency. The generated `doc/` and `.yardoc/` directories are ignored by Git.
