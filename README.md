# xitdb for Ruby

[`xitdb`](https://rubygems.org/gems/xitdb) provides transactional collections in one file, implemented in Ruby. It requires MRI 3.3 or later.
It requires no compiler or database service. Runtime dependencies are `date` and `bigdecimal`.

This is a Ruby implementation of [xitdb](https://github.com/xit-vcs/xitdb), a binary format for immutable database structures.
The repository is named `xitdb-ruby`; the gem and require path are `xitdb`.

The portable profile reads and writes upstream xitdb structures. The Ruby profile adds typed keys, ordered maps, and Ruby values.
Both profiles use the same storage core. Requiring the Ruby extension does not change portable behavior.

## Install

Add the gem to your application's bundle:

```sh
bundle add xitdb
```

Or install it directly:

```sh
gem install xitdb
```

## Quick start

Use String keys and portable values to share files with other xitdb implementations:

```ruby
require "xitdb"

XitDB.open("shared.xit") do |db|
  db.transaction { |root| root["profile"] = { "name" => "Ada", "visits" => 0 } }
  before = db.snapshot
  db.transaction { |root| root["profile"]["visits"] += 1 }
  p before.dig("profile", "visits")       # 0
  p db.snapshot.dig("profile", "visits")  # 1
end
```

Use the Ruby profile for Symbol keys, booleans, arbitrary-size integers, and other Ruby values:

```ruby
require "xitdb/ruby"

XitDB::Ruby.memory do |db|
  db.transaction do |root|
    root[:enabled] = true
    root[:large] = 2**200
  end
  p db.snapshot[:enabled] # true
end
```

## Choose a profile

| Entry point | Values and keys | File identifier |
| --- | --- | --- |
| `XitDB.open`, `XitDB.memory` | Portable integers, floats, bytes, collections, and String keys | `sha1` by default; `hash: :sha256` selects `sha2` |
| `XitDB::Ruby.open`, `XitDB::Ruby.memory` | Ruby scalar values, typed keys, and ordered maps and sets | `rb04` |
| `XitDB::Core::Database` | Raw slots, every upstream collection, and arbitrary roots | Explicit storage configuration |

Opening never converts a profile. Public entry points reject a mismatched profile and pre-existing zero-byte files.
Missing paths are created. Block forms close the handle; callers close handles returned without a block.

## Transactions and limits

Write through `db.transaction`. Normal block completion commits; an exception aborts the transaction.
Snapshots retain their committed values through later writes and remain usable until the database handle closes.
Transaction views expire when their block ends. Use `to_ruby` to obtain independent Ruby containers.

Writers serialize across cooperating threads and processes. Lock timeout raises `XitDB::BusyError` before the transaction block runs.
File commits synchronize data and root publication. A `XitDB::CommitError` reports whether publication failed, succeeded, or has an unknown outcome.
See [locking and durability](docs/core.md#locking-and-durability) before implementing retries.

Portable maps and sets require String keys or members; portable values exclude booleans and Symbols.
The Ruby profile supports these types and preserves insertion order in ordinary maps and sets.
Profile conversion is explicit. Conversion can duplicate shared data across histories; see [measurements and costs](docs/benchmarks.md).

Version 0.1.0 is the initial release. The public API can change before 1.0.

## Documentation

Start with [Learn xitdb](docs/learning.md) for a beginner's explanation of values, transactions, snapshots, profiles, and storage.
Ruby source includes YARD API comments. With YARD available, run `yard doc` and open `doc/index.html`.

Read the [portable guide](docs/portable.md), [Ruby guide](docs/ruby.md), and [core guide](docs/core.md).
The [Ruby wire contract](docs/ruby-profile-v4.md) defines compact native containers, indexed row pages, and exact scalar payloads.
Pinned references preserve opaque Ruby scalar bytes inside portable containers. Native `rb04` containers require the Core record extension.

## Run the workflows

1. Run `ruby examples/portable.rb` for nested updates, snapshots, history, streams, compaction, and replication.
2. Run `ruby examples/ruby.rb` for native values, codecs, cross-file copying, and explicit conversion.
3. Run `ruby examples/indexed_users.rb` for atomic record/index updates and sorted pagination.

Examples require the installed package and write temporary files only. Each emits one JSON object.
From a checkout, run them with `bundle exec ruby -Ilib examples/portable.rb`, substituting the example filename.

## Verify a checkout

Run `bundle install` to install the locked development dependencies.

Load `xitdb/ruby` directly from the checkout with `ruby -Ilib`. Run `bundle exec rake` for the complete quality gate.

The Linux memory gate uses the cached `ruby:4.0.9` image. It copies the Ruby sources into an isolated runtime before starting the measured container. Both containers run without network access.

Run `bundle exec ruby script/ci.rb` to check the checkout.
It checks Ruby style, library types, and Change Risk Anti-Patterns (CRAP), then inspects the locally built package.
The tests execute packaged examples from temporary storage and inspect package contents.
The package check uses an isolated application bundle and local gem resolution. It does not install dependencies from the network.

`bundle exec rake` runs the same checks using the locked development dependencies.
Plain `rake` also works when those versions are installed on Ruby's gem paths.
RuboCop loads the Minitest, Performance, and Rake plugins. Individual checks are available:

| Command | Check |
| --- | --- |
| `bundle exec rake rubocop` | Project style rules, with size metrics exempted |
| `bundle exec rake types` | Steep diagnostics and 100% typed calls in every library file |
| `bundle exec rake crap` | Fast tests with fresh SimpleCov coverage, then a CRAP limit of 10 |
| `bundle exec rake test` | Fast tests without the analysis tools |

RBS signatures ship in `sig/`. Custom codec results have an unknown type until callers validate their class.
Type coverage measures checked method calls. It does not prove that arbitrary codec output meets an application's domain constraints.

The workflow defines separate `reference` and `linux-memory` jobs alongside Linux MRI 3.3, 3.4, and 4.0 and macOS jobs.
Configure every job as a required branch check. Workflow definitions alone do not enable repository branch protection.
Reference tools are mandatory for `ruby script/interop.rb --all`; unavailable tools fail that gate.
The [measurement guide](docs/benchmarks.md) records bounded-memory evidence and conversion costs.

## Releases

See [CHANGELOG.md](CHANGELOG.md) for release changes and [the release guide](docs/releasing.md) for the publishing procedure.

## License

The package preserves the [MIT license notice](LICENSE). Upstream xitdb references remain pinned in `test/interop/manifest.json`.
