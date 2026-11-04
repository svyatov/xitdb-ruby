# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "optparse"
require "tmpdir"
require_relative "../lib/xitdb/core"

module Interop
  ROOT = File.expand_path("..", __dir__)
  MANIFEST = JSON.parse(File.read(File.join(ROOT, "test/interop/manifest.json")))

  def self.run
    options = {reference: "go", case: "empty"}
    OptionParser.new do |parser|
      parser.on("--reference NAME") { |name| options[:reference] = name }
      parser.on("--case CASE") { |name| options[:case] = name }
      parser.on("--all") { options[:all] = true }
    end.parse!
    raise "--all requires all four adapters; only Go is implemented" if options[:all]
    raise "unsupported reference: #{options[:reference]}" unless options[:reference] == "go"
    raise "unsupported case: #{options[:case]}" unless %w[empty scalars array-list hash-collections linked-array-insert linked-array-edit].include?(options[:case])

    reference = ENV.fetch("XITDB_GO_REFERENCE", "/tmp/xitdb-reference-go")
    verify_source(reference)
    Dir.mktmpdir("xitdb-interop-") do |dir|
      binary = File.join(dir, "go-adapter")
      env = {"GOCACHE" => File.join(Dir.tmpdir, "xitdb-go-build-cache"), "GOPROXY" => "off", "GOSUMDB" => "off"}
      command(env, "go", "build", "-o", binary, File.join(ROOT, "test/interop/go/main.go"), chdir: reference)
      if options[:case] == "empty"
        empty(binary, dir)
      elsif options[:case] == "array-list"
        array_list(binary, dir)
      elsif options[:case] == "hash-collections"
        hash_collections(binary, dir)
      elsif options[:case] == "linked-array-insert"
        linked_array_insert(binary, dir)
      elsif options[:case] == "linked-array-edit"
        linked_array_edit(binary, dir)
      else
        scalars(binary, dir)
      end
    end
    puts "Go #{options[:case]}: Ruby-to-Go and Go-to-Ruby passed"
  end

  def self.verify_source(path)
    pin = MANIFEST.fetch("references").fetch("go")
    raise "missing Go reference #{pin.fetch('repository')} at #{pin.fetch('revision')}: #{path}" unless File.file?(File.join(path, "go.mod"))

    digest = Digest::SHA256.new
    Dir.glob("*.go", base: path).sort.each do |file|
      digest.update(file).update("\0").update(File.binread(File.join(path, file)))
    end
    digest.update("go.mod\0").update(File.binread(File.join(path, "go.mod")))
    raise "Go reference differs from pinned source #{pin.fetch('revision')}" unless digest.hexdigest == pin.fetch("source_sha256")
  end

  def self.command(*args, **options)
    output, error, status = Open3.capture3(*args, **options)
    raise "#{args.inspect} failed: #{error}\n#{output}" unless status.success?

    output
  end

  def self.adapter(binary, operation, name, path, value = nil)
    request = {operation: operation, case: name, path: path, hash: MANIFEST.fetch("hash"),
               file_id: MANIFEST.fetch("file_id"), value: value}
    request[:values] = request.delete(:value) if name == "array-list"
    request.merge!(request.delete(:value)) if name == "hash-collections"
    request.merge!(request.delete(:value)) if %w[linked-array-insert linked-array-edit].include?(name)
    JSON.parse(command(binary, stdin_data: JSON.generate(request)))
  end

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

  def self.scalars(binary, dir)
    ruby_path = File.join(dir, "ruby.xit")
    go_path = File.join(dir, "go.xit")
    XitDB::Core::Database.open(ruby_path, file_id: 1) do |db|
      MANIFEST.fetch("scalars").each do |value|
        db.transaction do |cursor|
          slot = if value.key?("hex")
            db.bytes([value.fetch("hex")].pack("H*"), format_tag: value["format_tag"] && [value["format_tag"]].pack("H*"))
          else
            XitDB::Core::Slot.new(tag: value.fetch("tag").to_sym, value: Integer(value.fetch("bits")), full: value.fetch("full"))
          end
          cursor.replace(slot)
        end
        assert_equal value, adapter(binary, "read", "scalars", ruby_path)
        assert_equal value, adapter(binary, "write", "scalars", go_path, value)
        XitDB::Core::Database.open(go_path, readonly: true) { |reader| assert_equal value, read_value(reader) }
      end
    end
    puts "#{MANIFEST.fetch('scalars').length} scalar vectors checked in both directions"
  end

  def self.read_value(db)
    read_cursor_value(db.root_cursor)
  end

  def self.read_cursor_value(cursor)
    slot = cursor.slot
    value = {"tag" => slot.tag.to_s, "full" => slot.full}
    if %i[bytes short_bytes].include?(slot.tag)
      bytes = cursor.read_bytes
      value.merge("hex" => bytes.bytes.unpack1("H*"), "format_tag" => bytes.format_tag&.unpack1("H*"))
    else
      value.merge("bits" => slot.value.to_s)
    end
  end

  def self.array_list(binary, dir)
    [0, 1, 15, 16, 17, 255, 256, 257].each do |length|
      values = Array.new(length) do |index|
        {"tag" => "uint", "full" => false, "bits" => index.to_s}
      end
      values[0] = {"tag" => "none", "full" => false, "bits" => "0"} if length > 0
      values[1] = {"tag" => "none", "full" => true, "bits" => "0"} if length > 1
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
        assert_equal values, length.times.map { |index| read_cursor_value(list.cursor_at(index)) }
      end
    end
    puts "8 array lengths checked with sparse slots and occupied nulls in both directions"
  end

  def self.assert_equal(expected, actual)
    raise "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def self.hash_collections(binary, dir)
    scalar = ->(tag, bits = "0", full = false) { {"tag" => tag, "bits" => bits, "full" => full} }
    hashes = ["1" + "a" * 39, "2" + "a" * 39, "3" + "a" * 39, "0" * 39 + "1", "0" * 39 + "f"]
    vectors = hashes.each_with_index.map do |hash, index|
      {"hash" => hash, "key" => scalar.call("uint", (index + 1).to_s), "value" => scalar.call("uint", (index + 7).to_s)}
    end
    vectors[0]["key"] = scalar.call("int", "18446744073709551615")
    vectors[0]["value"] = scalar.call("none")
    vectors[2]["key"] = scalar.call("float", "9223372036854775808")
    vectors[2]["value"] = scalar.call("none", "0", true)
    vectors[4]["key"] = {"tag" => "bytes", "hex" => "00" * 9, "format_tag" => "7273", "full" => true}
    vectors << vectors[4].merge("key" => scalar.call("uint", "999"), "value" => scalar.call("uint", "77"))
    XitDB::Core::HashMap::TAGS.each do |tag|
      [[], vectors].each_with_index do |entries, index|
        removals = index.zero? ? [] : [hashes[1], hashes[3]]
        request = {"collection" => tag.to_s, "entries" => entries, "removals" => removals}
        final = index.zero? ? [] : [vectors[0], vectors[2], vectors[4].merge("value" => scalar.call("uint", "77"))]
        expected = {"tag" => tag.to_s, "count" => final.size, "entries" => final.sort_by { |entry| entry.fetch("hash") }, "missing" => true}
        ruby_path = File.join(dir, "ruby-#{tag}-#{index}.xit")
        XitDB::Core::Database.open(ruby_path, file_id: 1) do |db|
          db.transaction do |root|
            map = XitDB::Core::HashMap.new(root, counted: tag.to_s.start_with?("counted"), set: tag.to_s.end_with?("set"))
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
            {"hash" => hash.unpack1("H*"), "key" => hash_value(db, key), "value" => hash_value(db, value)}
          end
          assert_equal expected.fetch("entries"), actual.sort_by { |entry| entry.fetch("hash") }
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
    puts "4 hash tags checked empty and populated, with deep collisions, removals, raw keys, key-only records, and occupied nulls"
  end

  def self.hash_slot(db, value)
    if value.key?("hex")
      db.bytes([value.fetch("hex")].pack("H*"), format_tag: value["format_tag"] && [value["format_tag"]].pack("H*"))
    else
      XitDB::Core::Slot.new(tag: value.fetch("tag").to_sym, value: Integer(value.fetch("bits")), full: value.fetch("full"))
    end
  end

  def self.linked_array_insert(binary, dir)
    [0, 17, 257, 4097].each do |length|
      random = Random.new(61)
      oracle = []
      positions = Array.new(length) do |index|
        position = random.rand(0..index)
        oracle.insert(position, index.to_s)
        position
      end
      request = {"positions" => positions}
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
          assert_equal oracle, length.times.map { |index| list.get(index).value.to_s }
          assert_equal oracle.last(2), list.each_from_index([length - 2, 0].max).map { |slot| slot.value.to_s }
        end
      end
    end
    puts "4 linked-array lengths checked with seeded insertion, per-insert counts, rank reads, and suffix iteration"
  end

  def self.hash_value(db, slot)
    read_cursor_value(XitDB::Core::Cursor.new(database: db, slot: slot, bound: db.committed_size))
  end

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
      request = {"length" => length, "deletions" => deletions, "split_index" => split, "offset" => offset, "size" => size}
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
        assert_equal expected, list.map { |slot| slot.value.to_s }
      end
    end
    puts "5 linked-array edit lengths checked with first/middle/final removals, root collapse, split/rejoin, slices, and empty operands"
  end
end

Interop.run if $PROGRAM_NAME == __FILE__
