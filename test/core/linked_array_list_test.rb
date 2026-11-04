# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../support/fault_store"

class LinkedArrayListTest < Minitest::Test
  Core = XitDB::Core

  def test_slot_equality_compares_tag_occupancy_and_raw_payload
    slot = Core::Slot.float(-0.0)
    assert_equal slot, Core::Slot.parse(slot.to_bytes)
    refute_equal slot, Core::Slot.float(0.0)
    refute_equal Core::Slot.uint(0), Core::Slot.int(0)
    refute_equal Core::Slot.new, Core::Slot.null
    refute_equal slot, nil
  end

  def test_split_concat_and_root_collapse
    Core::Database.memory.transaction do |root|
      list = Core::LinkedArrayList.new(root)
      257.times { |i| list.append(Core::Slot.uint(i)) }
      left, right = list.split(17)
      assert_equal (0...17).to_a, left.each.map(&:value)
      assert_equal (17...257).to_a, right.each.map(&:value)
      assert_equal list.each.to_a, left.concat(right).each.to_a
      oracle = (0...257).to_a
      random = Random.new(71)
      tree = Core::BTree.new(root)
      until oracle.empty?
        rank = random.rand(oracle.size)
        assert_equal oracle.delete_at(rank), tree.delete_at(rank).value
        assert_equal oracle, tree.each_from_index(0).map(&:value)
      end
      assert_equal 0, list.size
      assert_equal :linked_array_list, root.slot.tag
      assert_equal [], list.split(0).first.to_a
      assert_empty root.transaction.instance_variable_get(:@checkpoints)
    end
  end

  def test_slices_and_concatenation_preserve_sources_and_detached_ownership
    Dir.mktmpdir do |dir|
      path = File.join(dir, "shared.xit")
      Core::Database.open(path) do |db|
        db.transaction do |root|
          list = Core::LinkedArrayList.new(root)
          4097.times { |i| list.append(Core::Slot.uint(i)) }
          original = root.slot
          length = root.transaction.length
          left, right = list.split(2049)
          assert_equal original, root.slot
          assert_operator root.transaction.length - length, :<, 20_000
          slice = list.slice(16, 257)
          assert_equal (16...273).to_a, slice.map(&:value)
          joined = left.concat(right)
          length = root.transaction.length
          doubled = list.concat(list)
          assert_operator root.transaction.length - length, :<, 10_000
          assert_equal 8194, doubled.size
          left.put(0, Core::Slot.uint(9999))
          right.append(Core::Slot.uint(8888))
          list.put(2049, Core::Slot.uint(7777))
          assert_equal (0...4097).to_a, joined.map(&:value)
          assert_equal (16...273).to_a, slice.map(&:value)
          root.replace(joined.cursor.slot)
          assert_empty root.transaction.instance_variable_get(:@checkpoints)
        end
      end
      Core::Database.open(path, readonly: true) do |db|
        assert_equal (0...4097).to_a, Core::LinkedArrayList.new(db.root_cursor).map(&:value)
      end
    end
  end

  def test_empty_operands_unequal_heights_and_self_concatenation
    Core::Database.memory.transaction do |root|
      list = Core::LinkedArrayList.new(root)
      257.times { |i| list.append(Core::Slot.uint(i)) }
      empty = list.slice(0, 0)
      small = list.slice(-1, 1)
      assert_equal (0...257).to_a, empty.concat(list).map(&:value)
      assert_equal (0...257).to_a, list.concat(empty).map(&:value)
      assert_equal [], empty.concat(empty).map(&:value)
      assert_equal (0...257).to_a + [256], list.concat(small).map(&:value)
      assert_equal [256] + (0...257).to_a, small.concat(list).map(&:value)
      doubled = list.concat(list)
      list.put(0, Core::Slot.uint(999))
      assert_equal (0...257).to_a * 2, doubled.map(&:value)
      doubled.put(0, Core::Slot.uint(888))
      assert_equal 0, doubled.get(257).value
      assert_equal 999, list.get(0).value
      assert_equal [], list.split(0).first.map(&:value)
      assert_equal [], list.split(list.size).last.map(&:value)
      assert_raises(IndexError) { list.split(258) }
      assert_raises(IndexError) { list.slice(256, 2) }
      assert_raises(IndexError) { list.slice(0, -1) }
      assert_raises(TypeError) { list.split(1.0) }
      assert_raises(TypeError) { list.slice(0, nil) }
    end
  end

  def test_seeded_splits_and_slices_preserve_every_rank
    Core::Database.memory.transaction do |root|
      tree = Core::BTree.new(root)
      oracle = (0...513).to_a.shuffle(random: Random.new(73))
      oracle.each { |value| tree.insert(tree.size, Core::Slot.uint(value)) }
      random = Random.new(79)
      [0, 1, 8, 16, 17, 256, 512, 513, *Array.new(20) { random.rand(0..513) }].each do |rank|
        left, right = tree.split(rank)
        assert_equal oracle.first(rank), left.each_from_index(0).map(&:value)
        assert_equal oracle.drop(rank), right.each_from_index(0).map(&:value)
        assert_equal oracle, left.concat(right).each_from_index(0).map(&:value)
        length = random.rand(0..(513 - rank))
        assert_equal oracle.slice(rank, length), tree.slice(rank, length).each_from_index(0).map(&:value)
      end
      assert_equal oracle.last(17), tree.split(-17).last.each_from_index(0).map(&:value)
    end
  end

  def test_shared_handles_expire_and_snapshot_operand_keeps_its_values
    db = Core::Database.memory
    db.transaction { |root| Core::LinkedArrayList.new(root).append(Core::Slot.uint(1)) }
    old = Core::LinkedArrayList.new(db.root_cursor)
    result = nil
    db.transaction do |root|
      list = Core::LinkedArrayList.new(root)
      list.append(Core::Slot.uint(2))
      result = list.concat(old)
      assert_equal [1, 2, 1], result.map(&:value)
      assert_equal [1], old.map(&:value)
    end
    assert_raises(XitDB::ExpiredViewError) { result.size }
    assert_raises(XitDB::ReadOnlyError) { old.split(0) }
    assert_raises(XitDB::ReadOnlyError) { old.slice(0, 0) }
    assert_raises(XitDB::ReadOnlyError) { old.concat(old) }
  end

  def test_cross_database_rejection_and_failed_shared_operation_roll_back
    store = FaultStore.new(Core::MemoryStore.new)
    foreign = Core::Database.memory
    foreign.transaction { |root| Core::LinkedArrayList.new(root).append(Core::Slot.uint(9)) }
    Core::Database.new(store: store).transaction do |root|
      list = Core::LinkedArrayList.new(root)
      17.times { |i| list.append(Core::Slot.uint(i)) }
      before = root.slot
      length = root.transaction.length
      assert_raises(XitDB::ForeignValueError) { list.concat(Core::LinkedArrayList.new(foreign.root_cursor)) }
      assert_equal length, root.transaction.length
      store.fault = ->(name, _) { raise IOError, "allocation failed" if name == :append }
      assert_raises(IOError) { list.split(8) }
      assert_raises(IOError) { list.concat(list) }
      store.fault = nil
      assert_equal before, root.slot
      assert_equal length, root.transaction.length
      assert_equal (0...17).to_a, list.map(&:value)
      assert_empty root.transaction.instance_variable_get(:@checkpoints)
    end
  ensure
    store.fault = nil if store
  end
end
