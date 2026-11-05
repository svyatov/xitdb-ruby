# xitdb for Ruby

xitdb provides transactional collections in one file, implemented in Ruby. It supports MRI 3.3 and later.
It requires no compiler or database service. Runtime dependencies are Ruby's shipped `date` and `bigdecimal` gems.

The portable profile reads and writes upstream xitdb structures. The Ruby profile adds typed keys, ordered maps, and Ruby values.
Both profiles use the same storage core. Requiring the Ruby extension does not change portable behavior.

## Use the package

Add `gem "xitdb"` to your application's Gemfile when the package is available from your configured source.
For a local checkout, build with `gem build xitdb.gemspec`. Install that artifact with `gem install --local xitdb-0.1.0.gem`.
These instructions do not imply that a release has been published.

```ruby
require "xitdb"

XitDB.open("shared.xit") do |db|
  db.transaction { |root| root["profile"] = {"name" => "Ada", "visits" => 0} }
  before = db.snapshot
  db.transaction { |root| root["profile"]["visits"] += 1 }
  p before.dig("profile", "visits")       # 0
  p db.snapshot.dig("profile", "visits")  # 1
end
```

```ruby
require "xitdb/ruby"

XitDB::Ruby.memory do |db|
  db.transaction { |root| root[:enabled] = true; root[:large] = 2**200 }
  p db.snapshot[:enabled] # true
end
```

## Choose a profile

| Entry point | Values and keys | File identifier |
| --- | --- | --- |
| `XitDB.open`, `XitDB.memory` | Portable integers, floats, bytes, collections, and String keys | `sha1` by default; `hash: :sha256` selects `sha2` |
| `XitDB::Ruby.open`, `XitDB::Ruby.memory` | Ruby scalar values, typed keys, and ordered maps and sets | `rb01` |
| `XitDB::Core::Database` | Raw slots, every upstream collection, and arbitrary roots | Explicit storage configuration |

Opening never converts a profile. Public entry points reject a mismatched profile and pre-existing zero-byte files.
Missing paths are created. Block forms close the handle; callers close handles returned without a block.

Read the [portable guide](docs/portable.md), [Ruby guide](docs/ruby.md), and [core guide](docs/core.md).
The [Ruby wire contract](docs/ruby-profile-v1.md) defines cross-language interpretation of `rb01`.
Other languages can preserve Ruby-profile bytes without decoding their logical values.

## Run the workflows

1. Run `ruby examples/portable.rb` for nested updates, snapshots, history, streams, compaction, and replication.
2. Run `ruby examples/ruby.rb` for native values, codecs, cross-file copying, and explicit conversion.
3. Run `ruby examples/indexed_users.rb` for atomic record/index updates and sorted pagination.

Examples require the installed package and write temporary files only. Each emits one JSON object.

## Verify a checkout

Run `ruby script/ci.rb` with the development gems from `Gemfile.lock` available.
It checks Ruby style, library types, and Change Risk Anti-Patterns (CRAP), then inspects the locally built package.
The tests execute packaged examples from temporary storage and inspect package contents.
The package check uses an isolated application bundle and local gem resolution. It does not install dependencies from the network.

`bundle exec rake` runs the same checks. Individual checks are available:

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

## License

The package preserves the [MIT license notice](LICENSE). Upstream xitdb references remain pinned in `test/interop/manifest.json`.
