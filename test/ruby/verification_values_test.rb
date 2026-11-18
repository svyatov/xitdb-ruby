# frozen_string_literal: true

require_relative "test_helper"
require "xitdb/ruby"
require "xitdb/verification/graph"
require "xitdb/verification/ruby_values"
require "tmpdir"
require "json"

class VerificationValuesTest < Minitest::Test
  Wire = XitDB::Ruby::Wire
  Scan = XitDB::Verification::Scan

  def verify(payloads, format: "rb", rows: nil, limits: {})
    Dir.mktmpdir do |dir|
      path = File.join(dir, "values.xit")
      core = XitDB::Core::Database.open(path, hash_id: "rb05", hash_size: 32)
      slots = []
      begin
        core.transaction do |cursor|
          slots = payloads.map { |bytes| core.bytes(bytes, format_tag: format) }
          XitDB::Core::ArrayList.new(cursor, fields: [slots.first])
        end
      ensure
        core.close
      end
      Scan.open(path, limits: limits) do |scan|
        verifier = XitDB::Verification::RubyValues.new(scan)
        @largest_read = 0
        observer = ->(size) { @largest_read = [size, @largest_read].max }
        scan.define_singleton_method(:read) do |offset, size|
          observer.call(size)
          super(offset, size)
        end
        slots.each do |slot|
          @start = slot.tag == :bytes ? slot.value + 8 : scan.root_offset + 1
          if rows
            verifier.page!(slot, count: rows, offset: scan.root_offset, path: "$/pages")
          else
            verifier.scalar!(slot, offset: scan.root_offset, path: "$/value")
          end
        end
        scan.codec_ids
      end
    end
  end

  def test_builtin_wire_values
    fixture = JSON.parse(File.read(File.expand_path("../fixtures/ruby/v1/scalars.json", __dir__)))
    values = fixture.values_at("values", "standard_values").flatten.filter_map { |entry| entry["payload"] }

    assert_equal ["acme"], verify(values.map { |hex| [hex].pack("H*") })
    %w[0201 01ff 010302 01040100 0102017800 0109000000 010800000230310000].each do |hex|
      error = assert_raises(XitDB::VerificationError) { verify([[hex].pack("H*")]) }
      assert_equal "$/value", error.path
    end
  end

  def test_codec_framing_and_inventory
    id = "example/custom"
    bytes = "x" * 180_000
    envelope = "\x01\x0a".b + Wire.t(id) + Wire.b(bytes)
    ids = verify([envelope, envelope], limits: { scalar_bytes: 1024 })

    assert_equal [id], ids
    assert_predicate ids.first, :frozen?
    assert_predicate ids, :frozen?
    assert_operator @largest_read, :<=, 65_536
    assert_equal 65_536, @largest_read
    %w[00 01ff00 01618100 01610261 01610061].each do |hex|
      assert_raises(XitDB::VerificationError) { verify(["\x01\x0a".b + [hex].pack("H*")]) }
    end
    error = assert_raises(XitDB::VerificationLimitError) { verify([envelope], limits: { codec_bytes: 2 }) }
    assert_equal :codec_bytes, error.limit
  end

  def test_graph_inventories_values_written_with_an_application_codec
    codec = XitDB::Ruby::Codec.new(id: "app/v1", type: Struct.new(:bytes), dump: lambda(&:bytes),
                                   load: ->(*) { flunk "codec loader called" })
    Dir.mktmpdir do |dir|
      path = File.join(dir, "codec.xit")
      XitDB::Ruby.open(path, codecs: [codec]) do |db|
        db.transaction { |root| root[:entry] = codec.type.new("opaque") }
      end
      Scan.open(path) do |scan|
        XitDB::Verification::Graph.new(scan).verify!(scan.root, role: :ruby_root)

        assert_equal [codec.id], scan.codec_ids
      end
    end
  end

  def test_tagged_string_streams_bytes_in_its_declared_encoding
    bytes = "\xff".b * 150_000
    text = "\x01\x01".b + Wire.t("UTF-8") + Wire.b(bytes)

    assert_empty verify([text], limits: { scalar_bytes: 512 })
    assert_equal 65_536, @largest_read
    assert_raises(XitDB::VerificationError) { verify(["\x01\x02".b + Wire.t("UTF-8") + Wire.b("\xff".b)]) }
    assert_raises(XitDB::VerificationError) { verify(["\x01\x01".b + Wire.t("unknown-encoding") + Wire.b("a")]) }
  end

  def test_scalar_budget_covers_numeric_work
    payload = "\x01\x04".b + Wire.z(1 << 4000)
    error = assert_raises(XitDB::VerificationLimitError) { verify([payload], limits: { scalar_bytes: 600 }) }
    assert_equal :scalar_bytes, error.limit
  end

  def test_page_layouts_and_locations
    codec = XitDB::Ruby::PageCodec
    rows = [{ "a" => nil }, { "a" => nil }]
    sequential = XitDB::Ruby::PageEncoder.new.encode(rows)
    fixed = codec.encode_page(rows)
    padded = codec.encode_page([rows.first, { "a" => "" }])
    directory = codec.encode_page([rows.first, { "a" => "many bytes in the second row" }])
    pages = [sequential, fixed, padded, directory]

    assert_equal(%w[XP01 XF01 XA01 XR01], pages.map { |bytes| bytes.byteslice(0, 4) })
    assert_empty verify(pages, format: nil, rows: 2)
    changed = fixed.dup
    changed.setbyte(10, 255)
    error = assert_raises(XitDB::VerificationError) { verify([changed], format: nil, rows: 2) }
    assert_equal @start, error.offset
    error = assert_raises(XitDB::VerificationError) { verify([checksum(changed)], format: nil, rows: 2) }
    assert_equal @start + 10, error.offset
    assert_includes error.path, "row[1]"
    assert_includes error.path, "field[0]"
    padded.setbyte(10, 1)
    directory[11, 2] = [0].pack("S<")

    [checksum(padded), checksum(directory), "#{sequential}\0"].each do |bad|
      assert_raises(XitDB::VerificationError) { verify([bad], format: nil, rows: 2) }
    end
    assert_raises(XitDB::VerificationError) { verify([fixed], format: nil, rows: 1) }
  end

  private

  def checksum(bytes)
    body = bytes.byteslice(0, bytes.bytesize - 32)
    body + Digest::SHA256.digest(body)
  end
end
