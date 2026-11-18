# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "xitdb/verification/graph"

class VerificationGraphTest < Minitest::Test
  Core = XitDB::Core
  Slot = Core::Slot
  Header = Data.define(:data_offset, :hash_size)

  # Small synthetic records let checks assert the precise source field.
  class Fixture
    attr_reader :data, :budget

    def initialize(limits = {})
      @data = "\0".b * 32
      @budget = XitDB::Verification::Budget.new(limits)
    end

    def append(bytes)
      start = data.size
      data << bytes
      start
    end

    def block(slots)
      append(slots.map(&:to_bytes).join.ljust(144, "\0"))
    end

    def array(slots)
      Slot.new(tag: :array_list, value: append([slots.size, block(slots)].pack("Q>Q>")))
    end

    def read(offset, size) = Core::Format.slice(data, offset, size)
    def bound = data.size + Core::Database::TRAILER_SIZE
    def header = Header.new(32, 20)
    def history_offsets = []
    def root_offset = 31
  end

  def setup
    @fixture = Fixture.new
  end

  def test_shared_partial_array_views
    block = @fixture.block([Slot.uint(1), Slot.uint(2)])
    views = [1, 2].map do |count|
      Slot.new(tag: :array_list, value: @fixture.append([count, block].pack("Q>Q>")))
    end
    roots = [@fixture.array(views), @fixture.array(views.reverse)]

    roots.each { |root| assert_nil verify(root) }
    @fixture.data[block + 9, 9] = Slot.new(tag: 123).to_bytes

    assert_nil verify(views.first)
    roots.each { |root| assert_defect(:slot, block + 9, root) }
  end

  def test_sparse_array
    block = @fixture.block([])
    array = @fixture.append([65_537, block].pack("Q>Q>"))

    assert_nil verify(Slot.new(tag: :array_list, value: array))
  end

  def test_graph_limits_release_retained_state_after_failure
    { references: 1, depth: 1, path_bytes: 1, summary_bytes: 1 }.each do |name, limit|
      @fixture = Fixture.new(name => limit)
      root = @fixture.array([Slot.null])
      2.times do
        error = assert_raises(XitDB::VerificationLimitError) { verify(root) }

        assert_equal name, error.limit
      end
      assert_equal :released, @fixture.budget.with(name, limit) { :released }
    end
  end

  def test_cycle_and_extent
    root = @fixture.array([Slot.null])
    block = @fixture.data.byteslice(root.value + 8, 8).unpack1("Q>")
    @fixture.data[block, 9] = root.to_bytes

    assert_defect(:cycle, block, root)
    outside = @fixture.data.size
    @fixture.data[block, 9] = Slot.new(tag: :bytes, value: outside).to_bytes

    assert_defect(:extent, outside, root)
  end

  def test_record_reused_in_incompatible_layout
    record = @fixture.append([0, 0].pack("NN"))
    root = @fixture.array([Slot.new(tag: :record, value: record), Slot.new(tag: :bytes, value: record)])
    block = @fixture.data.byteslice(root.value + 8, 8).unpack1("Q>")

    assert_defect(:layout, block + 9, root)
  end

  def test_scalar_flags_and_inline_padding
    [Slot.uint(42), Slot.int(-1), Slot.float(3.5), Slot.null, Slot.new].each do |slot|
      assert_nil verify(slot)
    end
    assert_defect(:null, 31, Slot.new(value: 1))
    assert_defect(:slot_flag, 31, Slot.new(tag: :uint, full: true))
    assert_defect(:inline_padding, 31, Slot.new(tag: :short_bytes, value: 1))
    assert_defect(:root, 31, Slot.int(3), :portable_root)
  end

  def test_record_fields_and_count
    pointer = @fixture.append([123, 1].pack("NN") + Slot.int(16).to_bytes)
    root = Slot.new(tag: :record, value: pointer)

    assert_nil verify(root)
    @fixture.data[pointer + 4, 4] = [33].pack("N")

    assert_defect(:record_count, pointer + 4, root)
  end

  def test_streamed_hash_keys
    Dir.mktmpdir do |dir|
      %i[sha1 sha256 sha384 sha512].each do |hash|
        path = File.join(dir, hash.to_s)
        XitDB.open(path, hash: hash) do |db|
          db.transaction { |root| root["s" * 150_000] = Core::ByteValue.new("x", format_tag: "zz") }
        end

        XitDB::Verification::Scan.open(path) do |scan|
          assert_nil XitDB::Verification::Graph.new(scan).verify!(scan.root, role: :portable_root)
        end
      end
    end
  end

  def test_hash_route_digest_and_count
    digest = Digest::SHA1.digest("x")
    key = Slot.new(tag: :short_bytes, value: "x".ljust(8, "\0").unpack1("Q>"))
    pair = @fixture.append(digest + key.to_bytes + Slot.null.to_bytes)
    count = @fixture.append([1].pack("Q>"))
    slots = Array.new(16, Slot.new)
    slots[digest.getbyte(-1) & 15] = Slot.new(tag: :kv_pair, value: pair)
    @fixture.block(slots)
    root = Slot.new(tag: :counted_hash_map, value: count)

    assert_nil verify(root, :portable_root)
    @fixture.data[count, 8] = [2].pack("Q>")

    assert_defect(:count, count, root, :portable_root)
    @fixture.data[count, 8] = [1].pack("Q>")
    @fixture.data.setbyte(pair, digest.getbyte(0) ^ 1)

    assert_defect(:key_digest, pair, root, :portable_root)
    @fixture.data.setbyte(pair + 19, digest.getbyte(-1) ^ 1)

    assert_defect(:hash_route, pair, root, :portable_root)
  end

  def test_sorted_separators_and_order
    key = ->(str) { Slot.new(tag: :short_bytes, value: str.ljust(8, "\0").unpack1("Q>")) }
    header = [0, 2].pack("CC")
    leaves = [%w[a b], %w[d e]].map do |keys|
      @fixture.append(header + keys.map { |str| key.call(str).to_bytes }.join.ljust(144, "\0"))
    end
    children = leaves.map { |ptr| Slot.new(tag: :index, value: ptr).to_bytes }.join.ljust(144, "\0")
    separators = (Slot.new.to_bytes + key.call("c").to_bytes).ljust(144, "\0")
    node = @fixture.append([1, 2].pack("CC") + children + separators + [2, 2].pack("Q>*").ljust(128, "\0"))
    root = Slot.new(tag: :sorted_map, value: @fixture.append([4, node].pack("Q>Q>")))

    assert_nil verify(root, :portable_root)
    @fixture.data[node + 155, 9] = key.call("z").to_bytes

    assert_defect(:separator, node + 155, root, :portable_root)
    @fixture.data[leaves.first + 11, 9] = key.call("a").to_bytes

    assert_defect(:key_order, leaves.first + 11, root, :portable_root)
  end

  def verify(root, role = :physical)
    XitDB::Verification::Graph.new(@fixture).verify!(root, role: role)
  end

  def assert_defect(check, offset, root, role = :physical)
    error = assert_raises(XitDB::VerificationError) { verify(root, role) }

    assert_equal [check, offset], [error.check, error.offset]
  end

  def test_public_collections
    Dir.mktmpdir do |dir|
      path = File.join(dir, "portable")
      XitDB.open(path) do |db|
        db.transaction do |root|
          [XitDB.map, XitDB.map(counted: true), XitDB.sorted_map].each_with_index do |kind, i|
            root["m#{i}"] = kind
            40.times { |n| root["m#{i}"][n.to_s] = n }
          end
          [XitDB.set, XitDB.set(counted: true), XitDB.sorted_set].each_with_index do |kind, i|
            root["s#{i}"] = kind
            40.times { |n| root["s#{i}"].add(n.to_s) }
          end
          [XitDB.array, XitDB.linked_array].each_with_index do |kind, i|
            root["a#{i}"] = kind
            40.times { |n| root["a#{i}"] << n }
          end
          root["tagged"] = Core::ByteValue.new("z" * 70_000, format_tag: "zz")
        end
      end

      XitDB::Verification::Scan.open(path) do |scan|
        assert_nil XitDB::Verification::Graph.new(scan).verify!(scan.root, role: :portable_root)
      end
    end
  end
end
