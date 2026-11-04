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
    raise "unsupported case: #{options[:case]}" unless %w[empty scalars].include?(options[:case])

    reference = ENV.fetch("XITDB_GO_REFERENCE", "/tmp/xitdb-reference-go")
    verify_source(reference)
    Dir.mktmpdir("xitdb-interop-") do |dir|
      binary = File.join(dir, "go-adapter")
      env = {"GOCACHE" => File.join(Dir.tmpdir, "xitdb-go-build-cache"), "GOPROXY" => "off", "GOSUMDB" => "off"}
      command(env, "go", "build", "-o", binary, File.join(ROOT, "test/interop/go/main.go"), chdir: reference)
      if options[:case] == "empty"
        empty(binary, dir)
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
    slot = db.root_cursor.slot
    value = {"tag" => slot.tag.to_s, "full" => slot.full}
    if %i[bytes short_bytes].include?(slot.tag)
      bytes = db.read_bytes(slot)
      value.merge("hex" => bytes.bytes.unpack1("H*"), "format_tag" => bytes.format_tag&.unpack1("H*"))
    else
      value.merge("bits" => slot.value.to_s)
    end
  end

  def self.assert_equal(expected, actual)
    raise "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

Interop.run if $PROGRAM_NAME == __FILE__
