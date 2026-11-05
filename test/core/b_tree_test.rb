# frozen_string_literal: true

# Regression tests for counted tree splits, deletion, rank lookup, and malformed nodes.

require "test_helper"
require "tmpdir"
require "timeout"
require_relative "../support/fault_store"

# Covers counted tree splits, deletion, rank lookup, and malformed nodes.
# @api private
class BTreeTest < Minitest::Test
  Core = XitDB::Core

  # Checks root collapse rejects a cyclic surviving child.
  def test_root_collapse_rejects_a_cyclic_surviving_child
    Core::Database.memory.transaction do |root|
      tx = root.transaction
      leaf = tx.append([0, 1].pack("CC") + Core::Slot.uint(7).to_bytes + ("\0" * 135))
      cyclic = tx.length
      child = Core::Slot.new(tag: :index, value: cyclic)
      tx.append([1, 1].pack("CC") + child.to_bytes + ("\0" * 135) + [1].pack("Q>") + ("\0" * 120))
      branch = tx.append([1,
                          2].pack("CC") + Core::Slot.new(tag: :index,
                                                         value: leaf).to_bytes + child.to_bytes + ("\0" * 126) + [
                                                           1, 1
                                                         ].pack("Q>Q>") + ("\0" * 112))
      header = tx.append([2, branch].pack("Q>Q>"))
      root.replace(Core::Slot.new(tag: :linked_array_list, value: header))
      assert_raises(XitDB::CorruptionError) { Timeout.timeout(1) { Core::BTree.new(root).delete_at(0) } }
      assert_equal 2, Core::BTree.new(root).size
      assert_empty tx.instance_variable_get(:@checkpoints)
    end
  end

  # Checks first middle and final deletions collapse all tree heights.
  def test_first_middle_and_final_deletions_collapse_all_tree_heights
    Core::Database.memory.transaction do |root|
      tree = Core::BTree.new(root)
      oracle = (0...4097).to_a
      oracle.each { |value| tree.insert(tree.size, Core::Slot.uint(value)) }
      captured = root.transaction.cursor(slot: root.slot)
      child = Core::LinkedArrayList.new(root).cursor_at(10)

      assert_equal 0, tree.delete_at(0).value
      oracle.shift
      assert_raises(XitDB::ExpiredViewError) { child.slot }
      turn = 0
      until oracle.empty?
        index = [0, oracle.size / 2, -1][turn % 3]

        assert_equal oracle.delete_at(index), tree.delete_at(index).value
        assert_equal oracle.size, tree.size
        assert_equal oracle.size, subtree_count(root, tree_root(root)) if (turn % 128).zero? || oracle.size <= 17
        turn += 1
      end

      assert_equal [0, 0], root.database.read_at(tree_root(root), 2, bound: root.bound).unpack("CC")
      assert_nil tree.delete_at(0)
      assert_nil tree.delete_at(-1)
      assert_raises(TypeError) { tree.delete_at(nil) }
      assert_equal (0...4097).to_a, Core::BTree.new(captured).each_from_index(0).map(&:value)
    end
  end

  # Checks failed deletion restores live children and allocation.
  def test_failed_deletion_restores_live_children_and_allocation
    store = FaultStore.new(Core::MemoryStore.new)
    Core::Database.new(store: store).transaction do |root|
      list = Core::LinkedArrayList.new(root)
      17.times { |i| list.append(Core::Slot.uint(i)) }
      child = list.cursor_at(8)
      before = root.slot
      length = root.transaction.length
      store.fault = ->(name, _) { raise IOError, "allocation failed" if name == :append }
      assert_raises(IOError) { Core::BTree.new(root).delete_at(0) }
      store.fault = nil

      assert_equal before, root.slot
      assert_equal length, root.transaction.length
      assert_equal 8, child.slot.value
      assert_equal (0...17).to_a, list.map(&:value)
      assert_empty root.transaction.instance_variable_get(:@checkpoints)
    end
  ensure
    store.fault = nil if store
  end

  # Checks leaf and branch splits preserve rank.
  def test_leaf_and_branch_splits_preserve_rank
    Core::Database.memory.transaction do |root|
      tree = Core::BTree.new(root)
      4097.times { |i| tree.insert(i, Core::Slot.uint(i)) }

      assert_equal 4097, tree.size
      assert_equal 2048, tree.at(2048).value
      assert_equal [4095, 4096], tree.each_from_index(4095).map(&:value)
    end
  end

  # Checks seeded insertion preserves all counts and file ranks.
  def test_seeded_insertion_preserves_all_counts_and_file_ranks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tree.xit")
      oracle = []
      random = Random.new(61)
      Core::Database.open(path) do |db|
        db.transaction do |root|
          tree = Core::BTree.new(root)
          513.times do |i|
            rank = random.rand(0..oracle.size)
            oracle.insert(rank, i)
            tree.insert(rank, Core::Slot.uint(i))

            assert_equal oracle.size, tree.size
            assert_equal oracle.size, subtree_count(root, tree_root(root))
            assert_equal i, tree.at(rank).value
          end
          assert_equal oracle, tree.each_from_index(0).map(&:value)
          tree.replace(256, Core::Slot.uint(9999))
          oracle[256] = 9999
        end
      end
      Core::Database.open(path, readonly: true) do |db|
        tree = Core::BTree.new(db.root_cursor)

        assert_equal(oracle, oracle.each_index.map { |i| tree.at(i).value })
        assert_equal oracle[500..], tree.each_from_index(500).map(&:value)
      end
    end
  end

  # Checks that empty linked arrays retain their type and distinguish null values from missing indexes.
  def test_linked_array_empty_type_indexes_and_null_slots
    db = Core::Database.memory

    assert_equal 0, Core::LinkedArrayList.new(db.root_cursor).size
    assert_empty db.root_cursor.slot
    db.transaction do |root|
      list = Core::LinkedArrayList.new(root)

      assert_equal :linked_array_list, root.slot.tag
      assert_equal 0, list.size
      list.append(Core::Slot.new).append(Core::Slot.null).append(Core::Slot.uint(2))

      assert_empty list.get(0)
      assert list.get(-2).full
      assert_equal 2, list.get(-1).value
      assert_nil list.get(3)
      assert_nil list.get(-4)
      assert_equal %i[none none uint], list.map(&:tag)
      assert_equal [], list.each_from_index(3).to_a
      assert_raises(TypeError) { list.get(1.5) }
      assert_raises(IndexError) { Core::BTree.new(root).insert(4, Core::Slot.null) }
      assert_raises(IndexError) { Core::BTree.new(root).replace(3, Core::Slot.null) }
      assert_raises(XitDB::InvalidValueError) { list.append(Core::Slot.new(tag: :index)) }
    end
    assert_raises(XitDB::ReadOnlyError) { Core::LinkedArrayList.new(db.root_cursor).append(Core::Slot.null) }
  end

  # Checks nested children freeze replacement and restore.
  def test_nested_children_freeze_replacement_and_restore
    db = Core::Database.memory
    db.transaction do |root|
      list = Core::LinkedArrayList.new(root)
      list.append(Core::Slot.new)
      child = list.cursor_at(0)
      nested = Core::LinkedArrayList.new(child)
      nested.append(Core::Slot.uint(1))
      root.transaction.freeze
      captured = root.transaction.cursor(slot: root.slot)
      nested.append(Core::Slot.uint(2))

      assert_equal 1, Core::LinkedArrayList.new(Core::LinkedArrayList.new(captured).cursor_at(0)).size
      assert_equal 2, nested.size
      checkpoint = root.transaction.checkpoint
      list.put(0, Core::Slot.uint(3))
      assert_raises(XitDB::ExpiredViewError) { child.slot }
      root.transaction.restore(checkpoint)

      assert_equal 2, nested.size
      child.replace(Core::Slot.uint(4))

      assert_equal 4, list.get(0).value
      assert_empty root.transaction.instance_variable_get(:@checkpoints)
    end
  end

  # Checks failed insert restores root and operation checkpoint.
  def test_failed_insert_restores_root_and_operation_checkpoint
    store = FaultStore.new(Core::MemoryStore.new)
    Core::Database.new(store: store).transaction do |root|
      tree = Core::BTree.new(root)
      tree.insert(0, Core::Slot.uint(7))
      before = root.slot
      length = root.transaction.length
      store.fault = ->(name, _) { raise IOError, "allocation failed" if name == :append }
      assert_raises(IOError) { tree.insert(0, Core::Slot.uint(8)) }
      store.fault = nil

      assert_equal before, root.slot
      assert_equal length, root.transaction.length
      assert_equal [7], tree.each_from_index(0).map(&:value)
      assert_empty root.transaction.instance_variable_get(:@checkpoints)
    end
  ensure
    store.fault = nil if store
  end

  # Checks mixed array hash and linked children keep their paths.
  def test_mixed_array_hash_and_linked_children_keep_their_paths
    db = Core::Database.memory
    hash = "\x01".b * 20
    db.transaction do |root|
      length = root.transaction.length

      assert_nil root.child(kind: :linked_array_list, selector: 0)
      assert_empty root.slot
      assert_equal length, root.transaction.length
      outer = Core::ArrayList.new(root)
      outer.append(Core::Slot.new)
      map = Core::HashMap.new(outer.cursor_at(0), counted: true)
      map.put(hash, key: Core::Slot.uint(1), value: Core::Slot.null)
      linked_cursor = map.cursor_at(hash)
      linked = Core::LinkedArrayList.new(linked_cursor)
      linked.append(Core::Slot.new)
      array_cursor = linked_cursor.child(kind: :linked_array_list, selector: 0)
      inner = Core::ArrayList.new(array_cursor)
      inner.append(Core::Slot.uint(7))
      root.transaction.freeze
      captured = root.transaction.cursor(slot: root.slot)
      inner.put(0, Core::Slot.uint(8))
      old_map = Core::HashMap.from_cursor(Core::ArrayList.new(captured).cursor_at(0))
      old_inner = Core::ArrayList.new(Core::LinkedArrayList.new(old_map.cursor_at(hash)).cursor_at(0))

      assert_equal 7, old_inner.get(0).value
      assert_equal 8, inner.get(0).value
      outer.put(0, Core::Slot.uint(9))
      assert_raises(XitDB::ExpiredViewError) { array_cursor.slot }
    end
  end

  # Checks corrupt nodes and captured bounds are rejected.
  def test_corrupt_nodes_and_captured_bounds_are_rejected
    Core::Database.memory.transaction do |root|
      tx = root.transaction
      leaf = tx.append([0, 1].pack("CC") + Core::Slot.uint(7).to_bytes + ("\0" * 135))
      header = tx.append([2, leaf].pack("Q>Q>"))
      root.replace(Core::Slot.new(tag: :linked_array_list, value: header))
      assert_raises(XitDB::CorruptionError) { Core::BTree.new(root).at(0) }
      branch_bytes = [1, 1].pack("CC") + Core::Slot.new(tag: :index, value: tx.length).to_bytes
      branch = tx.append(branch_bytes + ("\0" * 135) + [1].pack("Q>") + ("\0" * 120))
      header = tx.append([1, branch].pack("Q>Q>"))
      root.replace(Core::Slot.new(tag: :linked_array_list, value: header))
      assert_raises(XitDB::CorruptionError) { Core::BTree.new(root).at(0) }
      header = tx.append([1, (1 << 64) - 1].pack("Q>Q>"))
      root.replace(Core::Slot.new(tag: :linked_array_list, value: header))
      assert_raises(XitDB::CorruptionError) { Core::BTree.new(root).at(0) }
    end
  end

  # Checks empty file type and committed child bounds survive reopening.
  def test_empty_file_type_and_committed_child_bounds_survive_reopening
    Dir.mktmpdir do |dir|
      path = File.join(dir, "linked.xit")
      Core::Database.open(path) { |db| db.transaction { |root| Core::LinkedArrayList.new(root) } }
      Core::Database.open(path) do |db|
        assert_equal :linked_array_list, db.root_cursor.slot.tag
        db.transaction do |root|
          list = Core::LinkedArrayList.new(root)
          list.append(db.bytes("original bytes"))
        end
        old = Core::LinkedArrayList.new(db.root_cursor)
        child = old.cursor_at(0)
        limit = child.bound
        db.transaction do |root|
          list = Core::LinkedArrayList.new(root)
          list.put(0, db.bytes("replacement bytes"))
          list.append(Core::Slot.uint(2))
        end

        assert_equal 1, old.size
        assert_equal "original bytes", child.read_bytes.bytes
        assert_equal limit, child.bound
        assert_raises(XitDB::ReadOnlyError) { child.replace(Core::Slot.null) }
      end
      Core::Database.open(path, readonly: true) do |db|
        list = Core::LinkedArrayList.new(db.root_cursor)

        assert_equal 2, list.size
        assert_equal "replacement bytes", list.cursor_at(0).read_bytes.bytes
      end
    end
  end

  # Checks tail iteration seeks by count instead of reading the prefix.
  def test_tail_iteration_seeks_by_count_instead_of_reading_the_prefix
    store = FaultStore.new(Core::MemoryStore.new)
    db = Core::Database.new(store: store)
    db.transaction do |root|
      list = Core::LinkedArrayList.new(root)
      4097.times { |i| list.append(Core::Slot.uint(i)) }
    end
    tree = Core::BTree.new(db.root_cursor)
    reads = 0
    store.fault = ->(name, _) { reads += 1 if name == :read_at }

    assert_equal [4095, 4096], tree.each_from_index(4095).map(&:value)
    assert_operator reads, :<, 100
  ensure
    store.fault = nil if store
  end

  private

  # Reads the root node pointer from a linked-array header.
  # @param cursor [XitDB::Core::Cursor] bounded linked-array cursor
  # @return [Integer] root node offset
  def tree_root(cursor)
    cursor.database.read_at(cursor.slot.value, 16, bound: cursor.bound).unpack("Q>Q>").last
  end

  # Checks stored child counts against recursive leaf counts.
  # @param cursor [XitDB::Core::Cursor] cursor supplying database and read bound
  # @param pointer [Integer] subtree node offset
  # @return [Integer] verified entry count
  def subtree_count(cursor, pointer)
    db = cursor.database
    kind, count = db.read_at(pointer, 2, bound: cursor.bound).unpack("CC")
    return count if kind.zero?

    children = db.read_at(pointer + 2, 144, bound: cursor.bound)
    counts = db.read_at(pointer + 146, 128, bound: cursor.bound).unpack("Q>*")
    count.times.sum do |i|
      child = Core::Slot.parse(children.byteslice(i * 9, 9))
      actual = subtree_count(cursor, child.value)

      assert_equal actual, counts[i]
      actual
    end
  end
end
