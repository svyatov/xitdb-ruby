# frozen_string_literal: true

require "test_helper"
require "timeout"

class PublicCollectionsTest < Minitest::Test
  def setup
    @db = XitDB.memory
  end

  def teardown
    @db.close unless @db.closed?
  end

  def test_array_gaps_sets_and_sorted_pages
    @db.transaction do |root|
      root["items"] = []
      root["items"][2] = "x"
      root["set"] = XitDB.set(counted: true)
      assert_same root["set"].class, root["set"].add("x").class
      root["set"].add("x").add("y")
      assert root["set"].include?("x")
      assert_equal 2, root["set"].size
      root["sorted"] = XitDB.sorted_map
      %w[c a b].each { |key| root["sorted"][key] = [key] }
    end
    items = @db.snapshot["items"]
    assert_equal [nil, nil, "x"], items.to_ruby
    assert_equal "x", items[-1]
    assert_kind_of Enumerator, items.each
    sorted = @db.snapshot["sorted"]
    assert_equal 1, sorted.rank("b")
    assert_equal 2, sorted.rank("bb")
    assert_equal %w[b c], sorted.from("b").map { |key, _| key }
    assert_equal ["c"], sorted.from_index(-1).map { |key, _| key }
    assert_equal ["b"], sorted.page(offset: 1, limit: 1).map { |key, _| key }
    assert_kind_of XitDB::Views::Base, sorted.values.first
    assert_kind_of ::Array, sorted.map { |key, _| key }
  end

  def test_array_supported_reads_match_ruby
    @db.transaction { |root| root["items"] = [0, 1, 2, 3] }
    items = @db.snapshot["items"]
    ruby = [0, 1, 2, 3]
    [-6, -4, -1, 0, 3, 4, 5, 1.9].each { |index| assert_ruby_value ruby[index], items[index] }
    [0..2, 1...3, -3..-1, 4..5, 5..6, 2..1, ..1, 2.., -8..1].each do |range|
      expected = ruby[range]
      actual = items[range]
      assert_ruby_value expected, actual&.to_ruby
    end
    [[0, 2], [-2, 4], [4, 0], [4, 4], [5, 0], [0, -1], [-5, 2]].each do |args|
      assert_ruby_value ruby[*args], items[*args]&.to_ruby
    end
    assert_equal 4, items.length
    assert_equal 0, items.first
    assert_equal 3, items.last
    assert_equal [0, 1], items.first(2)
    assert_equal [2, 3], items.last(2)
    assert_equal :missing, items.fetch(8, :missing)
    assert_equal 16, items.fetch(8, :ignored) { |index| index * 2 }
    assert_raises(IndexError) { items.fetch(-5) }
    assert_raises(TypeError) { items["1"] }
    assert_raises(ArgumentError) { items.first(-1) }
    assert_raises(ArgumentError) { items.last(-1) }
    assert_raises(XitDB::ReadOnlyError) { items.push(1) }
  end

  def test_seeded_array_mutations_match_independent_ruby_arrays
    [XitDB.array, XitDB.linked_array].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"]
        ruby = []
        random = Random.new(817)
        100.times do
          value = random.rand(100)
          case random.rand(7)
          when 0
            index = random.rand(ruby.size + 4)
            assert_equal ruby[index] = value, items[index] = value
          when 1
            assert_same items, items.push(value, value + 1)
            ruby.push(value, value + 1)
          when 2
            index = random.rand(ruby.size + 3)
            ruby.insert(index, value)
            assert_same items, items.insert(index, value)
          when 3
            index = random.rand(ruby.size + 2) - 1
            assert_ruby_value ruby.delete_at(index), items.delete_at(index)
          when 4
            assert_ruby_value ruby.pop, items.pop
          when 5
            count = random.rand(4)
            assert_equal ruby.pop(count), items.pop(count)
          when 6
            ruby.concat([value])
            assert_same items, items.concat([value])
          end
          assert_equal ruby, items.to_ruby
        end
        assert_same items, items.clear
        assert_empty items
        assert_nil items.pop
        assert_equal [], items.pop(2)
        assert_raises(IndexError) { items[-1] = 2 }
        assert_raises(IndexError) { items.insert(-2, 2) }
      end
    end
  end

  def test_slices_capture_values_and_assignment_copies_only_selected_slots
    [XitDB.array, XitDB.linked_array].each do |declaration|
      captured = nil
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"]
        items.push({"v" => [1]}, 2, 3, 4)
        captured = items[0, 2]
        nested = captured[0]["v"]
        assert_raises(XitDB::ReadOnlyError) { captured[0] = 9 }
        assert_raises(XitDB::ReadOnlyError) { nested.push(9) }
        items[0]["v"].push(5)
        items.delete_at(0)
        assert_equal [{"v" => [1]}, 2], captured.to_ruby
        root["copy"] = captured[1..]
        root["empty"] = captured[2, 0]
        assert_equal [2], root["copy"].to_ruby
        assert_equal [], root["empty"].to_ruby
        root["copy"].push(7)
        assert_equal [2], captured[1..].to_ruby
        error = Thread.new { captured.size rescue $! }.value
        assert_kind_of XitDB::TransactionStateError, error
      end
      assert_raises(XitDB::ExpiredViewError) { captured.size }
      stable = @db.snapshot["items"][1..]
      @db.transaction { |root| root["items"].clear }
      assert_equal [3, 4], stable.to_ruby
    end
  end

  def test_removed_nested_values_survive_position_changes
    @db.transaction do |root|
      root["items"] = [{"a" => [1]}, [2], [3]]
      items = root["items"]
      removed = items.delete_at(0)
      assert_equal({"a" => [1]}, removed.to_ruby)
      assert_equal [[2], [3]], items.pop(2).map(&:to_ruby)
      assert_equal({"a" => [1]}, removed.to_ruby)
    end
  end

  def test_linked_split_preserves_source_and_concat_persists
    @db.transaction do |root|
      root["items"] = XitDB.linked_array
      items = root["items"].push(0, 1, 2, 3)
      left, right = items.split(-2)
      assert_equal [0, 1], left.to_ruby
      assert_equal [2, 3], right.to_ruby
      assert_equal [0, 1, 2, 3], items.to_ruby
      assert_raises(XitDB::ReadOnlyError) { left.clear }
      assert_raises(IndexError) { items.split(5) }
      assert_equal [[], [0, 1, 2, 3]], items.split(0).map(&:to_ruby)
      assert_same items, items.concat(right)
      assert_equal [0, 1, 2, 3, 2, 3], items.to_ruby
      items.concat(items)
    end
    assert_equal [0, 1, 2, 3, 2, 3] * 2, @db.snapshot["items"].to_ruby
  end

  def test_sets_and_sorted_sets_support_mutation_and_eager_enumerables
    [XitDB.set, XitDB.set(counted: true), XitDB.sorted_set].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"]
        assert_same items, items.add("c").add("a").add("b").add("a")
        assert_equal Set["a", "b", "c"], items.to_ruby
        assert_equal %w[a b c], items.map { |key| key }.sort
        assert_kind_of Enumerator, items.each
        if items.respond_to?(:rank)
          assert_equal 1, items.rank("b")
          assert_equal %w[b c], items.from("b").to_a
          assert_equal ["c"], items.page(offset: 2, limit: 8).to_a
          assert_equal [], items.page(offset: 0, limit: 0).to_a
          assert_raises(ArgumentError) { items.page(offset: 0, limit: -1).to_a }
        end
        assert_same items, items.delete("b")
        assert_same items, items.delete("absent")
        refute items.include?("b")
        assert_same items, items.clear
        assert_empty items
      end
    end
  end

  def test_array_iteration_preserves_replacements_and_rejects_order_changes
    @db.transaction do |root|
      root["items"] = [[1], [2], [3]]
      items = root["items"]
      iterator = items.each
      assert_equal [1], iterator.next.to_ruby
      items[1] = [9]
      assert_equal [9], iterator.next.to_ruby
      items.insert(0, 0)
      assert_raises(XitDB::ConcurrentModificationError) { iterator.next }
    end
  end

  def test_array_argument_boundaries_and_atomic_failure
    [XitDB.array, XitDB.linked_array].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"].push(1, 2)
        ruby = [1, 2]
        assert_equal ruby.insert(-10), items.insert(-10).to_ruby
        assert_equal ruby.insert(-1, 3, 4), items.insert(-1, 3, 4).to_ruby
        assert_equal ruby.insert(-ruby.size - 1, 0), items.insert(-items.size - 1, 0).to_ruby
        assert_same items, items << 5
        ruby << 5
        items.concat(items, items)
        ruby.concat(ruby, ruby)
        assert_equal ruby, items.to_ruby
        before = items.to_ruby
        length = items.context.transaction.length
        assert_raises(XitDB::UnsupportedValueError) { items.push(7, Object.new) }
        assert_equal before, items.to_ruby
        assert_equal length, items.context.transaction.length
        assert_raises(XitDB::UnsupportedValueError) { items.concat([8], [Object.new]) }
        assert_equal before, items.to_ruby
        assert_equal length, items.context.transaction.length
        assert_raises(ArgumentError) { items.pop(-1) }
        assert_raises(TypeError) { items.insert("1", 1) }
        assert_raises(TypeError) { items[0..1] = [9] }
        assert_raises(TypeError) { items.concat(1) }
        retained = items[0, 1]
        @db_other = XitDB.memory
        assert_raises(XitDB::ForeignValueError) { @db_other.transaction { |other| other["x"] = retained } }
        @db_other.close
      end
    end
  ensure
    @db_other&.close unless @db_other&.closed?
  end

  def test_linked_slices_and_sorted_pages_seek_without_scanning_skipped_values
    @db.transaction do |root|
      root["linked"] = XitDB.linked_array
      root["linked"].concat((0...4097).to_a)
      root["sorted"] = XitDB.sorted_map
      root["sorted"].merge!((0...4097).to_h { |index| [format("%08d", index), index] })
    end
    linked = @db.snapshot["linked"]
    sorted = @db.snapshot["sorted"]
    reads = count_reads do
      assert_equal [4095, 4096], linked[4095, 2].to_a
      assert_equal 0, linked[0, 4097].each.next
    end
    assert_operator reads, :<, 100
    reads = count_reads { assert_equal [4095, 4096], sorted.page(offset: 4095, limit: 2).map { |_key, value| value } }
    assert_operator reads, :<, 100
    reads = count_reads { assert_equal [4095, 4096], sorted.from("00004095").map { |_key, value| value } }
    assert_operator reads, :<, 150
    @db.transaction do |root|
      items = root["linked"]
      before = items.context.transaction.length
      left, right = items.split(2000)
      assert_equal 2000, left.size
      assert_equal 2097, right.size
      assert_equal before, items.context.transaction.length
      root["piece"] = right[2090, 7]
      assert_equal (4090...4097).to_a, root["piece"].to_ruby
      assert_operator items.context.transaction.length - before, :<, 20_000
      before = items.context.transaction.length
      items.concat(items)
      assert_equal 8194, items.size
      assert_operator items.context.transaction.length - before, :<, 20_000
    end
  end

  def test_sorted_iteration_and_snapshot_pages_keep_their_owner
    @db.transaction do |root|
      root["items"] = XitDB.sorted_map
      items = root["items"]
      items.merge!({"a" => [1], "b" => [2], "c" => [3]})
      iterator = items.page(offset: 0, limit: 3)
      assert_equal [1], iterator.next.last.to_ruby
      items["b"] = [9]
      assert_equal [9], iterator.next.last.to_ruby
      items.delete("a")
      assert_raises(XitDB::ConcurrentModificationError) { iterator.next }
    end
    snapshot = @db.snapshot
    page = snapshot["items"].page(offset: 0, limit: 3)
    @db.transaction { |root| root["items"].clear }
    assert_equal [["b", [9]], ["c", [3]]], page.map { |key, value| [key, value.to_ruby] }
    assert_raises(XitDB::ReadOnlyError) { snapshot["items"].delete("missing") }
    @db.close
    assert_raises(XitDB::ClosedError) { page.to_a }
  end

  def test_counted_end_reads_keep_transaction_children_writable
    @db.transaction do |root|
      root["items"] = [[1], [2]]
      items = root["items"]
      items.first(1).first.push(3)
      items.last(1).first.push(4)
      assert_equal [[1, 3], [2, 4]], items.to_ruby
      count = Object.new
      count.define_singleton_method(:to_int) { 1 }
      assert_equal [1], [1, 2].first(count)
      assert_equal [[1, 3]], items.first(count).map(&:to_ruby)
      assert_equal [[2, 4]], items.last(count).map(&:to_ruby)
      assert_equal [[2, 4]], items.pop(count).map(&:to_ruby)
    end
    items = @db.snapshot["items"]
    @db.close
    assert_raises(XitDB::ClosedError) { items.first(0) }
  end

  def test_integer_conversion_limits_match_ruby
    @db.transaction do |root|
      root["items"] = [1, 2]
      items = root["items"]
      [[:[], 1 << 100], [:first, 1 << 100], [:insert, 1 << 100], [:[], 0, 1 << 100],
       [:[], 5..(1 << 100)], [:[], -5..(1 << 100)]].each do |args|
        expected = assert_raises(RangeError) { [1, 2].public_send(*args) }
        assert_raises(expected.class) { items.public_send(*args) }
      end
    end
  end

  def test_empty_linked_concat_preserves_revision_and_iterator
    @db.transaction do |root|
      root["items"] = XitDB.linked_array
      root["items"].push(1, 2)
      root["empty"] = XitDB.linked_array
    end
    revisions = @db.history.size
    @db.transaction do |root|
      items = root["items"]
      iterator = items.each
      assert_equal 1, iterator.next
      items.concat(root["empty"])
      assert_equal 2, iterator.next
    end
    assert_equal revisions, @db.history.size
  end

  def test_oversized_array_growth_rejects_before_gap_allocation
    @db.transaction do |root|
      root["items"] = []
      items = root["items"]
      index = (1 << ([0].pack("l!").bytesize * 8 - 1)) - 1
      [[:[]=, index, 1], [:insert, index, 1]].each do |args|
        assert_raises(IndexError) { [].public_send(*args) }
        Timeout.timeout(1) { assert_raises(IndexError) { items.public_send(*args) } }
        assert_empty items
      end
    end
  end

  def test_empty_pages_still_check_database_lifetime
    @db.transaction { |root| root["sorted"] = XitDB.sorted_set }
    items = @db.snapshot["sorted"]
    @db.close
    assert_raises(XitDB::ClosedError) { items.page(offset: 0, limit: 0).to_a }
  end

  private

  def assert_ruby_value(expected, actual)
    expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
  end

  def count_reads
    count = 0
    trace = TracePoint.new(:call) do |event|
      count += 1 if event.defined_class == XitDB::Core::Database && event.method_id == :read_at
    end
    trace.enable { yield }
    count
  end
end
