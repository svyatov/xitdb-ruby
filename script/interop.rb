# frozen_string_literal: true

# Drives binary compatibility checks against pinned upstream implementations.
# Use --all for all cases or --generate-fixtures to rebuild fixtures.

require "digest"
require "json"
require "open3"
require "optparse"
require "tmpdir"
require_relative "../lib/xitdb/core"

# Runs binary compatibility cases against the pinned reference implementations.
# @api private
module Interop
  ROOT = File.expand_path("..", __dir__)
  MANIFEST = JSON.parse(File.read(File.join(ROOT, "test/interop/manifest.json")))
  KINDS = %w[array_list linked_array_list hash_map hash_set counted_hash_map counted_hash_set sorted_map
             sorted_set].freeze
  TOOL_ROOT = File.expand_path("~/.local/share/mise/installs")

  # Verifies pinned source and prepares an adapter in a temporary directory.
  # @param name [String] reference name from the manifest
  # @yieldparam invoke [Proc] adapter taking operation, case, path, and optional hash settings
  # @yieldparam dir [String] temporary directory
  # @return [Object] block result
  def self.with_reference(name)
    pin = MANIFEST.fetch("references").fetch(name)
    source = ENV.fetch("XITDB_#{name.upcase}_REFERENCE", "/private/tmp/xitdb-reference-#{name}")
    if name == "go"
      verify_source(source)
    else
      digest = Digest::SHA256.new
      files = Dir.glob(pin.fetch("source_glob"), base: source).sort
      files.each { |file| digest.update(file).update("\0").update(File.binread(File.join(source, file))) }
      unless digest.hexdigest == pin.fetch("source_sha256")
        raise "#{name} reference differs from #{pin.fetch("revision")}"
      end
    end
    Dir.mktmpdir("xitdb-#{name}-") do |dir|
      env = { "MISE_CACHE_DIR" => "/private/tmp/xitdb-mise-cache", "XITDB_REFERENCE" => source }
      executable = case name
                   when "go"
                     binary = File.join(dir, "adapter")
                     command(env.merge("GOCACHE" => "/private/tmp/xitdb-go-build-cache", "GOPROXY" => "off",
                                       "GOSUMDB" => "off"),
                             "go", "build", "-o", binary, File.join(ROOT, "test/interop/go/main.go"), chdir: source)
                     [binary]
                   when "typescript"
                     ["bun", File.join(ROOT, "test/interop/typescript/main.ts")]
                   when "java"
                     java = File.join(TOOL_ROOT, "java/temurin-25.0.5+8.0.LTS/bin")
                     command(File.join(java, "javac"), "-d", dir, *Dir.glob("#{source}/src/main/java/**/*.java"),
                             File.join(ROOT, "test/interop/java/Main.java"))
                     [File.join(java, "java"), "-cp", dir, "Main"]
                   when "zig"
                     binary = File.join(dir, "adapter")
                     command(File.join(TOOL_ROOT, "zig/0.17.0/zig"), "build-exe",
                             "--cache-dir", "/private/tmp/xitdb-zig-cache",
                             "--global-cache-dir", "/private/tmp/xitdb-zig-global-cache",
                             "-femit-bin=#{binary}", "--dep", "xitdb",
                             "-Mroot=#{ROOT}/test/interop/zig/main.zig", "-Mxitdb=#{source}/src/lib.zig")
                     [binary]
                   end
      invoke = lambda do |operation, kase, path, hash = MANIFEST.fetch("hash")|
        request = { operation: operation, case: kase, path: path, hash: hash,
                    file_id: "1", scalars: MANIFEST.fetch("scalars") }
        if File.file?(path) && File.size(path) >= 20
          header = File.binread(path, 20)
          request[:hash] = { id: header.byteslice(8, 4), size: header.byteslice(6, 2).unpack1("n") }
        end
        JSON.parse(command(env, *executable, stdin_data: JSON.generate(request)))
      end
      yield invoke, dir
    end
  end

  # Builds the normalized tree expected from the shared all-kinds fixture.
  # @param linked_hole [Boolean] whether the linked array retains its first empty slot
  # @return [Hash] tagged tree with raw bits and entries
  def self.expected_tree(linked_hole: false)
    items = MANIFEST.fetch("scalars").dup
    collection_sizes = [0, 17]
    KINDS.each do |kind|
      collection_sizes.each do |count|
        entries = Array.new(count) do |index|
          value = { "tag" => "uint", "full" => false, "bits" => index.to_s }
          if kind.end_with?("list")
            if index < 2
              { "tag" => "none", "full" => index == 1 || (kind == "linked_array_list" && !linked_hole),
                "bits" => "0" }
            else
              value
            end
          else
            [format("k%02d", index).unpack1("H*"), kind.end_with?("set") ? nil : value]
          end
        end
        items << { "tag" => kind, "items" => entries }
      end
    end
    { "tag" => "array_list",
      "items" => [{ "tag" => "uint", "full" => false, "bits" => "7" }, { "tag" => "array_list", "items" => items }] }
  end

  # Converts a raw cursor tree into the adapter's JSON-compatible representation.
  # @param cursor [XitDB::Core::Cursor] bounded cursor
  # @return [Hash] tagged scalar or normalized collection
  def self.normalized(cursor)
    core = XitDB::Core
    slot = cursor.slot
    return read_cursor_value(cursor) unless KINDS.include?(slot.tag.to_s)

    child = ->(value) { core::Cursor.new(database: cursor.database, slot: value, bound: cursor.bound) }
    items = case slot.tag
            when :array_list, :linked_array_list
              list = slot.tag == :array_list ? core::ArrayList.new(cursor) : core::LinkedArrayList.new(cursor)
              Array.new(list.size) { |index| normalized(list.cursor_at(index)) }
            when :hash_map, :hash_set, :counted_hash_map, :counted_hash_set
              core::HashMap.from_cursor(cursor).each_entry.map do |_hash, key, value|
                [child.call(key).read_bytes.bytes.unpack1("H*"),
                 slot.tag.to_s.end_with?("set") ? nil : normalized(child.call(value))]
              end.sort_by(&:first)
            else
              core::SortedMap.new(cursor).map do |key, value|
                [key.unpack1("H*"), slot.tag == :sorted_set ? nil : normalized(child.call(value))]
              end
            end
    { "tag" => slot.tag.to_s, "items" => items }
  end

  # Reads and normalizes a database without changing its file.
  # @param path [String] database path
  # @return [Hash] normalized root
  def self.read_tree(path)
    XitDB::Core::Database.open(path, readonly: true) { |db| normalized(db.root_cursor) }
  end

  # Writes a full base image and incremental delta beside the source file.
  # @param db [XitDB::Core::Database] committed source
  # @param path [String] prefix for .base and .delta files
  # @param first [Integer] boundary between the two exports
  def self.export_parts(db, path, first)
    File.open("#{path}.base", "wb") { |io| db.read_committed(0, first, io) }
    File.open("#{path}.delta", "wb") { |io| db.read_committed(first, db.committed_size, io) }
  end

  # Writes the Ruby all-kinds fixture and its base and delta exports.
  # @param path [String] destination path
  # @param hash_size [Integer] hash width in bytes
  # @param hash_id [String] four-byte hash identifier
  def self.write_tree(path, hash_size: 20, hash_id: "sha1")
    core = XitDB::Core
    collection_sizes = [0, 17]
    core::Database.open(path, file_id: 1, hash_size: hash_size, hash_id: hash_id) do |db|
      db.transaction { |root| core::ArrayList.new(root).append(core::Slot.uint(7)) }
      first = db.committed_size
      db.transaction do |root|
        history = core::ArrayList.new(root)
        history.append(core::Slot.new)
        list = core::ArrayList.new(history.cursor_at(1))
        MANIFEST.fetch("scalars").each do |value|
          slot = if value.key?("hex")
                   db.bytes([value.fetch("hex")].pack("H*"),
                            format_tag: value["format_tag"] && [value["format_tag"]].pack("H*"))
                 else
                   core::Slot.new(tag: value.fetch("tag").to_sym, full: value.fetch("full"),
                                  value: Integer(value.fetch("bits")))
                 end
          list.append(slot)
        end
        KINDS.each do |kind|
          collection_sizes.each do |count|
            list.append(core::Slot.new)
            cursor = list.cursor_at(list.size - 1)
            collection = case kind
                         when "array_list" then core::ArrayList.new(cursor)
                         when "linked_array_list" then core::LinkedArrayList.new(cursor)
                         when "sorted_map", "sorted_set" then core::SortedMap.new(cursor, set: kind.end_with?("set"))
                         else core::HashMap.new(cursor, counted: kind.start_with?("counted"),
                                                        set: kind.end_with?("set"))
                         end
            count.times do |index|
              key = format("k%02d", index)
              value = core::Slot.uint(index)
              if kind.end_with?("list")
                collection.append(index < 2 ? core::Slot.new(full: index == 1) : value)
              elsif kind.start_with?("sorted")
                kind.end_with?("set") ? collection.add(key) : collection.put(key, value: value)
              else
                hash = (hash_size == 48 ? Digest::SHA384 : Digest::SHA1).digest(key)
                if kind.end_with?("set")
                  collection.add(hash,
                                 key: db.bytes(key))
                else
                  collection.put(hash, key: db.bytes(key),
                                       value: value)
                end
              end
            end
          end
        end
      end
      export_parts(db, path, first)
    end
  end

  # Checks that Ruby rejects an interrupted delta and then applies the complete reference delta.
  # @param path [String] reference path with exported replication parts
  def self.check_ruby_replication(path)
    core = XitDB::Core
    base = File.binread("#{path}.reference.base")
    delta = File.binread("#{path}.reference.delta")
    require "stringio"
    copy = core::Database.copy_replica(to: "#{path}.ruby-replica", source_io: StringIO.new(base), length: base.bytesize)
    begin
      previous = copy.replica_state
      begin
        copy.apply_replicated(base.bytesize, StringIO.new(delta.byteslice(0, delta.bytesize / 2)), delta.bytesize)
        raise "Ruby accepted an interrupted replica"
      rescue EOFError
        assert_equal previous, copy.replica_state
      end
      copy.apply_replicated(base.bytesize, StringIO.new(delta), delta.bytesize)
      assert_equal File.binread(path), File.binread("#{path}.ruby-replica")
    ensure
      copy.close
    end
  end

  # Checks compaction and interrupted replication in both implementations.
  # @param invoke [Proc] reference adapter
  # @param path [String] source path with base and delta exports
  # @param expected [Hash] normalized source tree
  def self.check_maintenance(invoke, path, expected)
    original = File.binread(path)
    invoke.call("compact", "all-kinds", path)
    compacted = read_tree("#{path}.compact")
    assert_equal({ "tag" => "array_list", "items" => [expected.fetch("items").last] }, compacted)
    assert_equal original, File.binread(path)
    result = invoke.call("replicate", "all-kinds", path)
    assert_equal true, result.fetch("interrupted")
    assert_equal original, File.binread("#{path}.replica")
    assert_equal File.binread("#{path}.base"), File.binread("#{path}.reference.base")
    assert_equal File.binread("#{path}.delta"), File.binread("#{path}.reference.delta")
    check_ruby_replication(path)
    XitDB::Core::Database.open(path, readonly: true) { |db| db.compact(to: "#{path}.ruby-compact").close }
    assert_equal compacted, invoke.call("read", "all-kinds", "#{path}.ruby-compact").fetch("tree")
  end

  # Checks that reference maintenance preserves Ruby values and unknown codec bytes.
  # @param invoke [Proc] reference adapter
  # @param dir [String] scratch directory
  def self.check_opaque(invoke, dir)
    require_relative "../lib/xitdb/ruby"
    path = File.join(dir, "opaque.xit")
    type = Struct.new(:payload)
    payload = "opaque\0codec".b * 12_000
    codec = XitDB::Ruby::Codec.new(id: "interop/opaque/v1", type: type, dump: lambda(&:payload), load: lambda { |bytes|
      type.new(bytes)
    })
    XitDB::Ruby.open(path, codecs: [codec]) do |db|
      db.transaction { |tx| tx[:old] = "first" }
      first = File.size(path)
      db.transaction do |tx|
        tx[:opaque] = [2**100, :symbol, "a\0b".b, Time.at(1, 123_456_789, :nanosecond)]
        tx[:unknown] = type.new(payload)
      end
      XitDB::Core::Database.open(path, readonly: true) { |core| export_parts(core, path, first) }
    end
    expected = read_tree(path)
    check_maintenance(invoke, path, expected)
    XitDB::Ruby.open("#{path}.compact", readonly: true) do |db|
      assert_equal [2**100, :symbol, "a\0b".b, Time.at(1, 123_456_789, :nanosecond)], db.snapshot[:opaque].to_ruby
      assert_equal XitDB::Ruby::EncodedValue, db.snapshot[:unknown].class
      assert_equal "interop/opaque/v1", db.snapshot[:unknown].codec_id
    end
    XitDB::Ruby.open("#{path}.compact", readonly: true, codecs: [codec]) do |db|
      assert_equal payload, db.snapshot[:unknown].payload
    end
  end

  # Reads the runtime version for fixture provenance.
  # @param name [String] reference name
  # @return [String, nil] runtime description for a supported reference
  def self.runtime(name)
    env = { "MISE_CACHE_DIR" => "/private/tmp/xitdb-mise-cache" }
    case name
    when "go" then command(env, "go", "version").strip
    when "typescript" then "Bun #{command(env, "bun", "--version").strip}"
    when "java" then command(File.join(TOOL_ROOT, "java/temurin-25.0.5+8.0.LTS/bin/java"), "--version").strip
    when "zig" then "Zig #{command(File.join(TOOL_ROOT, "zig/0.17.0/zig"), "version").strip}"
    end
  end

  # Generates independent upstream fixtures and records source, adapter, and generator checksums.
  def self.generate_fixtures
    require "fileutils"
    require "time"
    MANIFEST.fetch("references").each do |name, pin|
      with_reference(name) do |invoke, dir|
        path = File.join(dir, "all-kinds.xit")
        assert_reference_result(name, invoke.call("write", "all-kinds", path))
        assert_equal expected_tree, read_tree(path)
        directory = File.join(ROOT, "test/fixtures/interop", name)
        FileUtils.mkdir_p(directory)
        fixture = File.join(directory, "all-kinds.xit")
        FileUtils.copy_file(path, fixture)
        extension = { "go" => "go", "typescript" => "ts", "zig" => "zig" }
        filename = name == "java" ? "Main.java" : "main.#{extension.fetch(name)}"
        adapter = File.join(ROOT, "test/interop", name, filename)
        provenance = pin.merge("runtime" => runtime(name), "generated_at" => Time.now.utc.iso8601,
                               "producer" => "pinned upstream library through test/interop/#{name}",
                               "fetch_command" => "gh api repos/#{pin.fetch("repository")}/tarball/" \
                                                  "#{pin.fetch("revision")}",
                               "generate_command" => "ruby script/interop.rb --generate-fixtures",
                               "generator_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
                               "adapter_sha256" => Digest::SHA256.file(adapter).hexdigest,
                               "manifest_sha256" => Digest::SHA256.file(
                                 File.join(ROOT, "test/interop/manifest.json")
                               ).hexdigest,
                               "fixture_sha256" => Digest::SHA256.file(fixture).hexdigest)
        File.write(File.join(directory, "provenance.json"), "#{JSON.pretty_generate(provenance)}\n")
        puts "#{name}: independent fixture generated and read by Ruby"
      end
    end
  end

  # Checks all-kinds files and maintenance in both directions between Ruby and a reference.
  # @param name [String] reference name
  def self.check_reference(name)
    with_reference(name) do |invoke, dir|
      path = File.join(dir, "reference.xit")
      assert_reference_result(name, invoke.call("write", "all-kinds", path))
      produced = expected_tree
      assert_equal produced, read_tree(path)
      check_maintenance(invoke, path, produced)
      ruby_path = File.join(dir, "ruby.xit")
      write_tree(ruby_path)
      assert_reference_result(name, invoke.call("read", "all-kinds", ruby_path), linked_hole: true)
      check_maintenance(invoke, ruby_path, expected_tree(linked_hole: true))
      check_opaque(invoke, dir)
      check_sha384(name, invoke, dir)
    end
    puts "#{name}: independent all-kinds writes, reads, history, compact, interrupted replication, " \
         "and opaque rb01 maintenance passed in both directions"
  end

  # Repeats all-kinds and maintenance checks with a 48-byte SHA-384 profile.
  # @param name [String] reference name
  # @param invoke [Proc] reference adapter
  # @param dir [String] scratch directory
  def self.check_sha384(name, invoke, dir)
    path = File.join(dir, "sha384-reference.xit")
    assert_reference_result(name, invoke.call("write", "all-kinds", path, { id: "s384", size: 48 }))
    assert_equal expected_tree, read_tree(path)
    check_maintenance(invoke, path, expected_tree)
    ruby_path = File.join(dir, "sha384-ruby.xit")
    write_tree(ruby_path, hash_size: 48, hash_id: "s384")
    assert_reference_result(name, invoke.call("read", "all-kinds", ruby_path), linked_hole: true)
    check_maintenance(invoke, ruby_path, expected_tree(linked_hole: true))
  end

  # Checks tree contents, iteration counts, and reference-specific integer behavior.
  # @param name [String] reference name
  # @param result [Hash] adapter response
  # @param linked_hole [Boolean] whether the source retains a linked-array hole
  def self.assert_reference_result(name, result, linked_hole: false)
    assert_equal expected_tree(linked_hole: linked_hole), result.fetch("tree")
    assert_equal [2, 34, 0, 16, 0, linked_hole ? 16 : 17], result.fetch("iteration")
    return unless %w[typescript java].include?(name)

    observed = result.fetch("numbers")
    %w[18446744073709551615 9223372036854775808 9223372036854775809].each do |bits|
      assert_equal({ "tag" => "uint", "bits" => bits, "error" => "ExpectedUnsignedLongException" },
                   observed.find { |value| value["tag"] == "uint" && value["bits"] == bits })
    end
    numbers = { "9007199254740991" => "9007199254740991", "9007199254740993" => "9007199254740992",
                "9223372036854775807" => "9223372036854776000", "9223372036854775808" => "-9223372036854776000" }
    numbers.each do |bits, number|
      number = Integer(bits) >= 2**63 ? (Integer(bits) - (2**64)).to_s : bits if name == "java"
      assert_equal({ "tag" => "int", "bits" => bits, "number" => number },
                   observed.find { |value| value["tag"] == "int" && value["bits"] == bits })
    end
    number = name == "java" ? "9223372036854775807" : "9223372036854776000"
    assert_equal({ "tag" => "uint", "bits" => "9223372036854775807", "number" => number },
                 observed.find { |value| value["tag"] == "uint" && value["bits"] == "9223372036854775807" })
    return unless name == "java" && result.key?("writer_rejections")

    assert_equal %w[18446744073709551615 9223372036854775808 9223372036854775809], result.fetch("writer_rejections")
  end

  # Parses command-line options and runs selected checks or fixture generation.
  def self.run
    options = { reference: "go", case: "empty" }
    OptionParser.new do |parser|
      parser.on("--reference NAME") { |name| options[:reference] = name }
      parser.on("--case CASE") { |name| options[:case] = name }
      parser.on("--all") { options[:all] = true }
      parser.on("--generate-fixtures") { options[:generate] = true }
    end.parse!
    return generate_fixtures if options[:generate]

    if options[:all]
      %w[empty scalars array-list hash-collections linked-array-insert linked-array-edit sorted-collections compaction
         replication].each do |name|
        run_go_case(name)
      end
      MANIFEST.fetch("references").each_key { |reference| check_reference(reference) }
      puts "Known pinned limits: TypeScript Number rounds integers outside its exact range; Java and " \
           "TypeScript readUint reject values above INT64_MAX. Java Uint writes also reject that " \
           "range; public Slot writes preserve it. Exact raw bits and maintenance pass."
      puts "Sparse constructors: array append cursors preserve holes; linked append cursors store " \
           "occupied nulls. Zig's returned linked cursor reports an empty slot before rereading. Ruby " \
           "linked holes retain their ranks and full bits; reference iterators skip holes."
      return
    end
    if %w[all-kinds signedness tags history opaque].include?(options[:case]) || options[:reference] != "go"
      raise "unsupported case: #{options[:case]}" unless %w[all-kinds scalars signedness tags history compaction
                                                            replication opaque].include?(options[:case])

      check_reference(options[:reference])
      return
    end
    run_go_case(options[:case])
  end

  # Builds the pinned Go adapter and runs one bidirectional compatibility case.
  # @param name [String] case name
  def self.run_go_case(name)
    options = { reference: "go", case: name }
    raise "unsupported reference: #{options[:reference]}" unless options[:reference] == "go"

    cases = %w[empty scalars array-list hash-collections linked-array-insert
               linked-array-edit sorted-collections compaction replication]
    raise "unsupported case: #{options[:case]}" unless cases.include?(options[:case])

    reference = ENV.fetch("XITDB_GO_REFERENCE", "/tmp/xitdb-reference-go")
    verify_source(reference)
    Dir.mktmpdir("xitdb-interop-") do |dir|
      binary = File.join(dir, "go-adapter")
      env = { "GOCACHE" => File.join(Dir.tmpdir, "xitdb-go-build-cache"), "GOPROXY" => "off", "GOSUMDB" => "off" }
      command(env, "go", "build", "-o", binary, File.join(ROOT, "test/interop/go/main.go"), chdir: reference)
      case options[:case]
      when "empty"
        empty(binary, dir)
      when "array-list"
        array_list(binary, dir)
      when "hash-collections"
        hash_collections(binary, dir)
      when "linked-array-insert"
        linked_array_insert(binary, dir)
      when "linked-array-edit"
        linked_array_edit(binary, dir)
      when "sorted-collections"
        sorted_collections(binary, dir)
      when "compaction"
        compaction(binary, dir)
      when "replication"
        replication(binary, dir)
      else
        scalars(binary, dir)
      end
    end
    puts "Go #{options[:case]}: Ruby-to-Go and Go-to-Ruby passed"
  end

  # Checks the Go module and source checksum against the pinned manifest.
  # @param path [String] upstream source directory
  def self.verify_source(path)
    pin = MANIFEST.fetch("references").fetch("go")
    unless File.file?(File.join(path, "go.mod"))
      raise "missing Go reference #{pin.fetch("repository")} at #{pin.fetch("revision")}: #{path}"
    end

    digest = Digest::SHA256.new
    Dir.glob("*.go", base: path).sort.each do |file|
      digest.update(file).update("\0").update(File.binread(File.join(path, file)))
    end
    digest.update("go.mod\0").update(File.binread(File.join(path, "go.mod")))
    return if digest.hexdigest == pin.fetch("source_sha256")

    raise "Go reference differs from pinned source #{pin.fetch("revision")}"
  end

  # Runs an external command and raises with captured output if it fails.
  # @param args [Array] executable, arguments, and optional environment
  # @return [String] standard output
  def self.command(*args, **)
    output, error, status = Open3.capture3(*args, **)
    raise "#{args.inspect} failed: #{error}\n#{output}" unless status.success?

    output
  end

  # Sends a JSON request to the Go adapter and parses its response.
  # @param binary [String] compiled adapter path
  # @param operation [String] adapter operation
  # @param name [String] case name
  # @param path [String] database path
  # @param value [Object, nil] case-specific values
  # @return [Object] parsed response
  def self.adapter(binary, operation, name, path, value = nil)
    request = { operation: operation, case: name, path: path, hash: MANIFEST.fetch("hash"),
                file_id: MANIFEST.fetch("file_id"), value: value }
    request[:values] = request.delete(:value) if name == "array-list"
    request.merge!(request.delete(:value)) if name == "hash-collections"
    request.merge!(request.delete(:value)) if %w[linked-array-insert linked-array-edit sorted-collections
                                                 compaction].include?(name)
    JSON.parse(command(binary, stdin_data: JSON.generate(request)))
  end

  # Checks that both implementations produce the exact empty database fixture.
  # @param binary [String] compiled Go adapter path
  # @param dir [String] scratch directory
  def self.empty(binary, dir)
    expected = File.read(File.join(ROOT, "test/fixtures/core/empty-v1.hex")).strip
    ruby_path = File.join(dir, "ruby.xit")
    XitDB::Core::Database.open(ruby_path, file_id: 1, &:close)
    assert_equal expected, adapter(binary, "read", "empty", ruby_path).fetch("file_hex")
    go_path = File.join(dir, "go.xit")
    assert_equal expected, adapter(binary, "write", "empty", go_path).fetch("file_hex")
    XitDB::Core::Database.open(go_path, readonly: true) do |db|
      assert_equal 62, db.committed_size
      assert_equal true, db.root_cursor.slot.empty?
    end
  end

  # Checks every scalar vector in both writing and reading directions.
  # @param binary [String] compiled Go adapter path
  # @param dir [String] scratch directory
  def self.scalars(binary, dir)
    ruby_path = File.join(dir, "ruby.xit")
    go_path = File.join(dir, "go.xit")
    XitDB::Core::Database.open(ruby_path, file_id: 1) do |db|
      MANIFEST.fetch("scalars").each do |value|
        db.transaction do |cursor|
          slot = if value.key?("hex")
                   db.bytes([value.fetch("hex")].pack("H*"),
                            format_tag: value["format_tag"] && [value["format_tag"]].pack("H*"))
                 else
                   XitDB::Core::Slot.new(tag: value.fetch("tag").to_sym, value: Integer(value.fetch("bits")),
                                         full: value.fetch("full"))
                 end
          cursor.replace(slot)
        end
        assert_equal value, adapter(binary, "read", "scalars", ruby_path)
        assert_equal value, adapter(binary, "write", "scalars", go_path, value)
        XitDB::Core::Database.open(go_path, readonly: true) { |reader| assert_equal value, read_value(reader) }
      end
    end
    puts "#{MANIFEST.fetch("scalars").length} scalar vectors checked in both directions"
  end

  # Normalizes the root scalar of a raw database.
  # @param db [XitDB::Core::Database] open database
  # @return [Hash] tag, occupancy, and raw payload
  def self.read_value(db)
    read_cursor_value(db.root_cursor)
  end

  # Normalizes raw scalar bits or byte payloads without numeric conversion.
  # @param cursor [XitDB::Core::Cursor] scalar cursor
  # @return [Hash] JSON-compatible scalar
  def self.read_cursor_value(cursor)
    slot = cursor.slot
    value = { "tag" => slot.tag.to_s, "full" => slot.full }
    if %i[bytes short_bytes].include?(slot.tag)
      bytes = cursor.read_bytes
      value.merge("hex" => bytes.bytes.unpack1("H*"), "format_tag" => bytes.format_tag&.unpack1("H*"))
    else
      value.merge("bits" => slot.value.to_s)
    end
  end

  # Checks radix boundary lengths, holes, and occupied nulls in both implementations.
  # @param binary [String] compiled Go adapter path
  # @param dir [String] scratch directory
  def self.array_list(binary, dir)
    [0, 1, 15, 16, 17, 255, 256, 257].each do |length|
      values = Array.new(length) do |index|
        { "tag" => "uint", "full" => false, "bits" => index.to_s }
      end
      values[0] = { "tag" => "none", "full" => false, "bits" => "0" } if length.positive?
      values[1] = { "tag" => "none", "full" => true, "bits" => "0" } if length > 1
      ruby_path = File.join(dir, "ruby-array-#{length}.xit")
      XitDB::Core::Database.open(ruby_path, file_id: 1) do |db|
        db.transaction do |root|
          list = XitDB::Core::ArrayList.new(root)
          values.each do |value|
            list.append(XitDB::Core::Slot.new(tag: value.fetch("tag").to_sym,
                                              full: value.fetch("full"), value: Integer(value.fetch("bits"))))
          end
        end
      end
      assert_equal values, adapter(binary, "read", "array-list", ruby_path)
      go_path = File.join(dir, "go-array-#{length}.xit")
      assert_equal values, adapter(binary, "write", "array-list", go_path, values)
      XitDB::Core::Database.open(go_path, readonly: true) do |db|
        list = XitDB::Core::ArrayList.new(db.root_cursor)
        assert_equal length, list.size
        assert_equal(values, Array.new(length) { |index| read_cursor_value(list.cursor_at(index)) })
      end
    end
    puts "8 array lengths checked with sparse slots and occupied nulls in both directions"
  end

  # Stops the script when an observation differs from its expected value.
  # @param expected [Object] expected value
  # @param actual [Object] observed value
  # @raise [RuntimeError] if the values differ
  # @return [nil]
  def self.assert_equal(expected, actual)
    raise "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  # Checks exports and incremental application with exact bytes, checksums, and opaque tags.
  # @param binary [String] compiled Go adapter path
  # @param dir [String] scratch directory
  def self.replication(binary, dir)
    core = XitDB::Core
    payload = "opaque\0replication".b * 6000
    ruby_path = File.join(dir, "ruby-replication")
    core::Database.open(ruby_path, file_id: 1) do |source|
      source.transaction { |root| root.replace(core::Slot.uint(7)) }
      first = source.committed_size
      source.transaction { |root| root.replace(source.bytes(payload, format_tag: "\xff\0".b)) }
      File.open("#{ruby_path}.base", "wb") { |io| source.read_committed(0, first, io) }
      File.open("#{ruby_path}.delta", "wb") { |io| source.read_committed(first, source.committed_size, io) }
      result = adapter(binary, "read", "replication", ruby_path)
      assert_equal first, result.fetch("first_size")
      assert_equal source.replica_state.checksum.to_s, result.fetch("checksum")
      assert_equal source.committed_size, result.fetch("size")
      assert_equal Digest::SHA256.hexdigest(payload), result.fetch("payload_sha256")
      assert_equal File.binread(ruby_path), File.binread("#{ruby_path}.replica")
    end
    go_path = File.join(dir, "go-replication")
    result = adapter(binary, "write", "replication", go_path)
    File.open("#{go_path}.base", "rb") do |io|
      copy = core::Database.copy_replica(to: "#{go_path}.replica", source_io: io, length: result.fetch("first_size"))
      begin
        assert_equal 7, copy.root_cursor.slot.value
        snapshot = copy.root_cursor
        core::Database.open(go_path, readonly: true) do |source|
          assert_equal result.fetch("first_size"), source.replication_start(copy.replica_state)
        end
        File.open("#{go_path}.delta", "rb") do |delta|
          copy.apply_replicated(result.fetch("first_size"), delta, delta.size)
        end
        assert_equal 7, snapshot.slot.value
        assert_equal result.fetch("checksum"), copy.replica_state.checksum.to_s
        assert_equal result.fetch("size"), copy.committed_size
        assert_equal payload, copy.root_cursor.read_bytes.bytes
        assert_equal "\xff\0".b, copy.root_cursor.read_bytes.format_tag
        assert_equal File.binread(go_path), File.binread("#{go_path}.replica")
      ensure
        copy.close
      end
    end
    puts "Historical full exports and incremental streams applied in both directions with exact " \
         "bytes, commit checksums, and opaque payload tags"
  end

  # Checks compaction of shared cyclic graphs and tagged bytes in both implementations.
  # @param binary [String] compiled Go adapter path
  # @param dir [String] scratch directory
  def self.compaction(binary, dir)
    core = XitDB::Core
    payload = "opaque\0payload".b * 6000
    %w[history raw].each do |kind|
      expected = { "history" => kind == "history" ? 1 : 0, "cycle" => true, "shared" => true,
                   "payload_sha256" => Digest::SHA256.hexdigest(payload), "tag" => "ff00",
                   "short" => "short", "short_tag" => "ff00" }
      source_path = File.join(dir, "ruby-#{kind}")
      ruby_path = "#{source_path}.compact"
      core::Database.open(source_path) do |db|
        db.transaction do |root|
          tx = root.transaction
          bytes = db.bytes(payload, format_tag: "\xff\0".b)
          short = db.bytes("short", format_tag: "\xff\0".b)
          position = tx.length
          graph = core::Slot.new(tag: kind == "history" ? :array_list : :index, value: position, full: true)
          tx.append([4, position + 16].pack("Q>Q>")) if kind == "history"
          tx.append(graph.to_bytes + bytes.to_bytes + bytes.to_bytes + short.to_bytes + ("\0".b * 108))
          if kind == "history"
            history = core::ArrayList.new(root)
            history.append(core::Slot.uint(10)).append(graph)
          else
            root.replace(graph)
          end
        end
        original = File.binread(source_path)
        db.compact(to: ruby_path).close
        assert_equal original, File.binread(source_path)
      end
      assert_equal expected, adapter(binary, "read", "compaction", ruby_path, { "collection" => kind })
      go_path = File.join(dir, "go-#{kind}")
      assert_equal expected, adapter(binary, "write", "compaction", go_path, { "collection" => kind })
      ["#{ruby_path}.go-compact", "#{go_path}.go-compact"].each do |path|
        core::Database.open(path, readonly: true) do |db|
          assert_compaction_graph(db, kind, payload)
          original = File.binread(path)
          compacted = db.compact(to: "#{path}.ruby-compact")
          begin
            assert_compaction_graph(compacted, kind, payload)
            assert_equal original, File.binread(path)
          ensure
            compacted.close
          end
        end
      end
    end
    puts "Cyclic history and arbitrary index roots compacted in both implementations with shared, " \
         "large, and unknown-tagged bytes"
  end

  # Checks that a compacted graph preserves cycles, sharing, and opaque payloads.
  # @param db [XitDB::Core::Database] compacted database
  # @param kind [String] history or raw graph fixture
  # @param payload [String] expected external payload
  def self.assert_compaction_graph(db, kind, payload)
    core = XitDB::Core
    graph = db.root_cursor.slot
    if kind == "history"
      history = core::ArrayList.new(db.root_cursor)
      assert_equal 1, history.size
      graph = history.get(0)
    end
    assert_equal true, graph.full
    pointer = kind == "history" ? db.read_at(graph.value + 8, 8, bound: db.committed_size).unpack1("Q>") : graph.value
    children = Array.new(4) { |i| core::Slot.parse(db.read_at(pointer + (i * 9), 9, bound: db.committed_size)) }
    assert_equal graph, children[0]
    assert_equal children[1], children[2]
    assert_equal payload, db.read_bytes(children[1]).bytes
    assert_equal "\xff\0".b, db.read_bytes(children[1]).format_tag
    assert_equal "short", db.read_bytes(children[3]).bytes
    assert_equal "\xff\0".b, db.read_bytes(children[3]).format_tag
  end

  # Checks each hash collection tag with collisions, removals, and key-only records.
  # @param binary [String] compiled Go adapter path
  # @param dir [String] scratch directory
  def self.hash_collections(binary, dir)
    scalar = ->(tag, bits = "0", full = false) { { "tag" => tag, "bits" => bits, "full" => full } }
    hashes = ["1#{"a" * 39}", "2#{"a" * 39}", "3#{"a" * 39}", "#{"0" * 39}1", "#{"0" * 39}f"]
    vectors = hashes.each_with_index.map do |hash, index|
      { "hash" => hash, "key" => scalar.call("uint", (index + 1).to_s),
        "value" => scalar.call("uint", (index + 7).to_s) }
    end
    vectors[0]["key"] = scalar.call("int", "18446744073709551615")
    vectors[0]["value"] = scalar.call("none")
    vectors[2]["key"] = scalar.call("float", "9223372036854775808")
    vectors[2]["value"] = scalar.call("none", "0", true)
    vectors[4]["key"] = { "tag" => "bytes", "hex" => "00" * 9, "format_tag" => "7273", "full" => true }
    vectors << vectors[4].merge("key" => scalar.call("uint", "999"), "value" => scalar.call("uint", "77"))
    XitDB::Core::HashMap::TAGS.each do |tag|
      [[], vectors].each_with_index do |entries, index|
        removals = index.zero? ? [] : [hashes[1], hashes[3]]
        request = { "collection" => tag.to_s, "entries" => entries, "removals" => removals }
        final = index.zero? ? [] : [vectors[0], vectors[2], vectors[4].merge("value" => scalar.call("uint", "77"))]
        expected = { "tag" => tag.to_s, "count" => final.size, "entries" => final.sort_by do |entry|
          entry.fetch("hash")
        end, "missing" => true }
        ruby_path = File.join(dir, "ruby-#{tag}-#{index}.xit")
        XitDB::Core::Database.open(ruby_path, file_id: 1) do |db|
          db.transaction do |root|
            map = XitDB::Core::HashMap.new(root, counted: tag.to_s.start_with?("counted"),
                                                 set: tag.to_s.end_with?("set"))
            entries.each do |entry|
              key = hash_slot(db, entry.fetch("key"))
              value = hash_slot(db, entry.fetch("value"))
              if value.empty?
                map.add([entry.fetch("hash")].pack("H*"), key: key)
              else
                map.put([entry.fetch("hash")].pack("H*"), key: key, value: value)
              end
            end
            removals.each { |hash| assert_equal true, map.remove([hash].pack("H*")) }
          end
        end
        assert_equal expected, adapter(binary, "read", "hash-collections", ruby_path, request)
        go_path = File.join(dir, "go-#{tag}-#{index}.xit")
        assert_equal expected, adapter(binary, "write", "hash-collections", go_path, request)
        XitDB::Core::Database.open(go_path, readonly: true) do |db|
          map = XitDB::Core::HashMap.from_cursor(db.root_cursor)
          assert_equal tag, db.root_cursor.slot.tag
          assert_equal final.size, map.size
          actual = map.each_entry.map do |hash, key, value|
            { "hash" => hash.unpack1("H*"), "key" => hash_value(db, key), "value" => hash_value(db, value) }
          end
          assert_equal(expected.fetch("entries"), actual.sort_by { |entry| entry.fetch("hash") })
          final.each do |entry|
            hash = [entry.fetch("hash")].pack("H*")
            assert_equal true, map.include?(hash)
            assert_equal entry.fetch("key"), hash_value(db, map.key(hash))
            assert_equal entry.fetch("value"), hash_value(db, map.get(hash))
          end
          assert_equal false, map.include?("\xff".b * 20)
        end
      end
    end
    puts "4 hash tags checked empty and populated, with deep collisions, removals, raw keys, " \
         "key-only records, and occupied nulls"
  end

  # Restores a raw slot from a scalar fixture description.
  # @param db [XitDB::Core::Database] destination for byte allocations
  # @param value [Hash] scalar description
  # @return [XitDB::Core::Slot] constructed slot
  def self.hash_slot(db, value)
    if value.key?("hex")
      db.bytes([value.fetch("hex")].pack("H*"), format_tag: value["format_tag"] && [value["format_tag"]].pack("H*"))
    else
      XitDB::Core::Slot.new(tag: value.fetch("tag").to_sym, value: Integer(value.fetch("bits")),
                            full: value.fetch("full"))
    end
  end

  # Checks linked-array insertion at tree boundaries in both implementations.
  # @param binary [String] compiled Go adapter path
  # @param dir [String] scratch directory
  def self.linked_array_insert(binary, dir)
    [0, 17, 257, 4097].each do |length|
      random = Random.new(61)
      oracle = []
      positions = Array.new(length) do |index|
        position = random.rand(0..index)
        oracle.insert(position, index.to_s)
        position
      end
      request = { "positions" => positions }
      ruby_path = File.join(dir, "ruby-linked-#{length}.xit")
      XitDB::Core::Database.open(ruby_path, file_id: 1) do |db|
        db.transaction do |root|
          tree = XitDB::Core::BTree.new(root)
          positions.each_with_index do |position, index|
            tree.insert(position, XitDB::Core::Slot.uint(index))
            assert_equal index + 1, tree.size
          end
        end
      end
      assert_equal oracle, adapter(binary, "read", "linked-array-insert", ruby_path, request)
      go_path = File.join(dir, "go-linked-#{length}.xit")
      assert_equal oracle, adapter(binary, "write", "linked-array-insert", go_path, request)
      [ruby_path, go_path].each do |path|
        XitDB::Core::Database.open(path, readonly: true) do |db|
          list = XitDB::Core::LinkedArrayList.new(db.root_cursor)
          assert_equal :linked_array_list, db.root_cursor.slot.tag
          assert_equal length, list.size
          assert_equal(oracle, Array.new(length) { |index| list.get(index).value.to_s })
          assert_equal(oracle.last(2), list.each_from_index([length - 2, 0].max).map { |slot| slot.value.to_s })
        end
      end
    end
    puts "4 linked-array lengths checked with seeded insertion, per-insert counts, rank reads, and suffix iteration"
  end

  # Normalizes a raw hash record slot within its database read boundary.
  # @param db [XitDB::Core::Database] containing database
  # @param slot [XitDB::Core::Slot] stored key or value
  # @return [Hash] normalized scalar
  def self.hash_value(db, slot)
    read_cursor_value(XitDB::Core::Cursor.new(database: db, slot: slot, bound: db.committed_size))
  end

  # Checks sorted maps and sets with binary keys, ranks, and prefix seeks.
  # @param binary [String] compiled Go adapter path
  # @param dir [String] scratch directory
  def self.sorted_collections(binary, dir)
    collection_sizes = [0, 17, 257, 4097]
    %w[sorted_map sorted_set].each do |tag|
      collection_sizes.each do |length|
        keys = ["", "\0", "a", "a\0", "aa", "b", "é".b, "\xff".b, "long-key-with-bytes"]
        keys.concat((0...[length - keys.size, 0].max).map { |i| format("k%08d", i) })
        keys = keys.first(length)
        entries = keys.each_with_index.map do |key, i|
          value = if tag == "sorted_set" || i.zero?
                    nil
                  else
                    { "tag" => "uint", "bits" => i.to_s, "full" => false }
                  end
          { "key_hex" => key.unpack1("H*"), "value" => value }
        end.shuffle(random: Random.new(8))
        if length.positive?
          entries << { "key_hex" => "62", "value" => { "tag" => "none", "bits" => "0", "full" => true } }
          entries << { "key_hex" => "62", "value" => nil }
        end
        removals = length.zero? ? [] : %w[00 6161 6b3030303030303031]
        final = {}
        entries.each do |entry|
          key = entry.fetch("key_hex")
          final[key] = entry.fetch("value") if !final.key?(key) || entry.fetch("value")
        end
        removals.each { |key| final.delete(key) }
        empty = { "tag" => "none", "bits" => "0", "full" => false }
        expected_entries = final.sort.map { |key, value| { "key_hex" => key, "value" => value || empty } }
        expected = { "tag" => tag, "count" => final.size, "entries" => expected_entries }
        request = { "collection" => tag, "sorted_entries" => entries, "removals" => removals }
        ruby_path = File.join(dir, "ruby-#{tag}-#{length}.xit")
        XitDB::Core::Database.open(ruby_path, file_id: 1) do |db|
          db.transaction do |root|
            map = XitDB::Core::SortedMap.new(root, set: tag == "sorted_set")
            entries.each do |entry|
              key = [entry.fetch("key_hex")].pack("H*")
              entry.fetch("value") ? map.put(key, value: hash_slot(db, entry.fetch("value"))) : map.add(key)
            end
            removals.each { |key| map.remove([key].pack("H*")) }
          end
        end
        assert_equal expected, adapter(binary, "read", "sorted-collections", ruby_path, request)
        go_path = File.join(dir, "go-#{tag}-#{length}.xit")
        assert_equal expected, adapter(binary, "write", "sorted-collections", go_path, request)
        XitDB::Core::Database.open(go_path, readonly: true) do |db|
          map = XitDB::Core::SortedMap.new(db.root_cursor)
          assert_equal tag, db.root_cursor.slot.tag.to_s
          assert_equal expected_entries.size, map.size
          actual = map.map { |key, slot| { "key_hex" => key.unpack1("H*"), "value" => hash_value(db, slot) } }
          assert_equal expected_entries, actual
          expected_entries.each_with_index do |entry, i|
            key = [entry.fetch("key_hex")].pack("H*")
            assert_equal true, map.include?(key)
            assert_equal i, map.rank(key)
            assert_equal entry.fetch("value"), hash_value(db, map.get(key))
            assert_equal key, map.at(i).first
          end
          tail = expected_entries.last(2).map { |entry| [entry.fetch("key_hex")].pack("H*") }
          assert_equal tail, map.each_from(tail.first || "").map(&:first)
          assert_equal tail, map.each_from_index([map.size - 2, 0].max).map(&:first)
        end
      end
    end
    puts "2 sorted tags and 4 lengths checked with byte keys, key-only records, replacement, " \
         "removal, ranks, and suffix iteration"
  end

  # Checks linked-array deletion, root collapse, splitting, concatenation, and slicing.
  # @param binary [String] compiled Go adapter path
  # @param dir [String] scratch directory
  def self.linked_array_edit(binary, dir)
    [0, 1, 17, 257, 4097].each do |length|
      oracle = (0...length).to_a
      deletions = []
      remove_count = length == 4097 ? 3 : length
      remove_count.times do |turn|
        index = [0, oracle.size / 2, -1][turn % 3]
        deletions << index
        oracle.delete_at(index)
      end
      split = [17, oracle.size].min
      offset = [16, oracle.size].min
      size = [257, oracle.size - offset].min
      request = { "length" => length, "deletions" => deletions, "split_index" => split, "offset" => offset,
                  "size" => size }
      expected = oracle.slice(offset, size).map(&:to_s)
      ruby_path = File.join(dir, "ruby-edit-#{length}.xit")
      XitDB::Core::Database.open(ruby_path, file_id: 1) do |db|
        db.transaction do |root|
          list = XitDB::Core::LinkedArrayList.new(root)
          length.times { |index| list.append(XitDB::Core::Slot.uint(index)) }
          deletions.each { |index| list.delete_at(index) }
          left, right = list.split(split)
          joined = left.concat(right)
          selected = joined.slice(offset, size)
          empty = selected.slice(0, 0)
          root.replace(empty.concat(selected).concat(empty).cursor.slot)
        end
      end
      assert_equal expected, adapter(binary, "read", "linked-array-edit", ruby_path, request)
      go_path = File.join(dir, "go-edit-#{length}.xit")
      assert_equal expected, adapter(binary, "write", "linked-array-edit", go_path, request)
      XitDB::Core::Database.open(go_path, readonly: true) do |db|
        list = XitDB::Core::LinkedArrayList.new(db.root_cursor)
        assert_equal :linked_array_list, db.root_cursor.slot.tag
        assert_equal expected.size, list.size
        assert_equal(expected, list.map { |slot| slot.value.to_s })
      end
    end
    puts "5 linked-array edit lengths checked with first/middle/final removals, root collapse, " \
         "split/rejoin, slices, and empty operands"
  end
end

Interop.run if $PROGRAM_NAME == __FILE__
