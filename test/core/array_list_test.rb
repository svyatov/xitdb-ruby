# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "weakref"
require_relative "../support/fault_store"

class ArrayListTest < Minitest::Test
  Core = XitDB::Core

  def test_constructing_a_writable_empty_array_persists_its_type
    Dir.mktmpdir do |dir|
      path = File.join(dir, "empty-array.xit")
      Core::Database.open(path) do |core|
        core.transaction { |root| assert_equal 0, Core::ArrayList.new(root).size }
        assert_equal :array_list, core.root_cursor.slot.tag
      end
      Core::Database.open(path, readonly: true) do |core|
        assert_equal :array_list, core.root_cursor.slot.tag
        assert_equal 0, Core::ArrayList.new(core.root_cursor).size
      end
    end
    core = Core::Database.memory
    original_size = core.committed_size

    assert_equal 0, Core::ArrayList.new(core.root_cursor).size
    assert_empty core.root_cursor.slot
    assert_equal original_size, core.committed_size
  end

  def test_reading_a_missing_child_does_not_initialize_a_writable_parent
    Core::Database.memory.transaction do |root|
      length = root.transaction.length

      assert_nil root.child(kind: :array_list, selector: 0)
      assert_empty root.slot
      assert_equal length, root.transaction.length
    end
  end

  def test_radix_boundaries_and_shared_history
    core = Core::Database.memory
    snapshots = {}
    [0, 1, 15, 16, 17, 255, 256, 257].each do |length|
      core.transaction do |root|
        list = Core::ArrayList.new(root)
        list.append(Core::Slot.uint(list.size)) while list.size < length

        assert_equal length, list.size
      end
      snapshots[length] = Core::ArrayList.new(core.root_cursor)
    end
    list = snapshots.fetch(257)
    old_list = snapshots.fetch(16)

    assert_equal 257, list.size
    assert_equal 256, list.get(-1).value
    assert_nil list.get(257)
    assert_equal 15, old_list.get(15).value
    core.transaction { |root| Core::ArrayList.new(root).put(15, Core::Slot.uint(999)) }

    assert_equal 15, old_list.get(15).value
    assert_equal 15, list.get(15).value
    assert_equal 999, Core::ArrayList.new(core.root_cursor).get(15).value
    snapshots.each { |length, snapshot| assert_equal length, snapshot.each.count }
  end

  def test_sparse_slots_occupied_nulls_and_negative_indexes
    Core::Database.memory.transaction do |root|
      list = Core::ArrayList.new(root)
      list.append(Core::Slot.new)
      list.append(Core::Slot.null)
      list.append(Core::Slot.uint(2))

      assert_empty list.get(0)
      assert list.get(-2).full
      assert_nil list.get(-4)
      assert_equal %i[none none uint], list.each.map(&:tag)
      list.put(-1, Core::Slot.uint(3))

      assert_equal 3, list.get(2).value
      assert_raises(IndexError) { list.put(3, Core::Slot.uint(4)) }
      assert_raises(IndexError) { list.cursor_at(-4, create: true) }
      assert_raises(TypeError) { list.get(1.0) }
      assert_equal 3, list.size
    end
  end

  def test_truncation_reduces_depth_and_clears_reappended_slots
    core = Core::Database.memory
    core.transaction do |root|
      list = Core::ArrayList.new(root)
      257.times { |i| list.append(Core::Slot.uint(i)) }
    end
    old = Core::ArrayList.new(core.root_cursor)
    [256, 17, 16, 1, 0].each do |length|
      core.transaction do |root|
        list = Core::ArrayList.new(root)
        list.truncate(length)

        assert_equal length, list.size
        assert_nil list.get(length)
        list.append(Core::Slot.null)

        assert list.get(-1).full
        list.truncate(length)
        assert_raises(IndexError) { list.truncate(length + 1) }
      end
    end

    assert_equal 256, old.get(-1).value
    assert_equal 257, old.each.count
  end

  def test_nested_children_reacquire_paths_after_freeze
    core = Core::Database.memory
    core.transaction do |root|
      outer = Core::ArrayList.new(root)
      outer.append(Core::Slot.new)
      child = root.child(kind: :array_list, selector: 0)
      nested = Core::ArrayList.new(child)
      nested.append(Core::Slot.uint(1))
      root.transaction.freeze
      captured = root.transaction.cursor(slot: root.slot)
      nested.append(Core::Slot.uint(2))

      assert_equal 1, Core::ArrayList.new(Core::ArrayList.new(captured).cursor_at(0)).size
      assert_equal 2, Core::ArrayList.new(outer.cursor_at(0)).size
      assert_equal 2, nested.get(-1).value
      outer.append(Core::Slot.uint(9))

      assert_equal 2, nested.size
      root.replace(Core::Slot.uint(4))
      assert_raises(XitDB::ExpiredViewError) { child.slot }
    end
  end

  def test_replacing_or_truncating_a_child_invalidates_old_descendants
    Core::Database.memory.transaction do |root|
      list = Core::ArrayList.new(root)
      list.append(Core::Slot.new)
      child = list.cursor_at(0)
      nested = Core::ArrayList.new(child)
      nested.append(Core::Slot.uint(1))
      grandchild = nested.cursor_at(0)
      list.put(0, Core::Slot.uint(4))
      assert_raises(XitDB::ExpiredViewError) { child.slot }
      assert_raises(XitDB::ExpiredViewError) { grandchild.slot }
      removed = list.cursor_at(0)
      list.truncate(0)
      list.append(Core::Slot.uint(9))
      assert_raises(XitDB::ExpiredViewError) { removed.slot }
    end
  end

  def test_checkpoint_restore_preserves_existing_children
    Core::Database.memory.transaction do |root|
      list = Core::ArrayList.new(root)
      list.append(Core::Slot.uint(1))
      child = list.cursor_at(0)
      checkpoint = root.transaction.checkpoint
      list.put(0, Core::Slot.uint(2))
      later = list.cursor_at(0)
      root.transaction.restore(checkpoint)

      assert_equal 1, child.slot.value
      assert_raises(XitDB::ExpiredViewError) { later.slot }
      child.replace(Core::Slot.uint(3))

      assert_equal 3, list.get(0).value
    end
  end

  def test_replacement_expires_descendants_obtained_through_another_view
    Core::Database.memory.transaction do |root|
      outer = Core::ArrayList.new(root)
      outer.append(Core::Slot.new)
      first = Core::ArrayList.new(outer.cursor_at(0))
      first.append(Core::Slot.new)
      second = Core::ArrayList.new(outer.cursor_at(0))
      stale = second.cursor_at(0)
      first.put(0, Core::Slot.uint(8))
      assert_raises(XitDB::ExpiredViewError) { stale.slot }
      assert_equal 8, second.get(0).value
    end
  end

  def test_reopened_files_and_captured_child_bounds
    Dir.mktmpdir do |dir|
      path = File.join(dir, "array.xit")
      old = nil
      Core::Database.open(path) do |core|
        core.transaction do |root|
          list = Core::ArrayList.new(root)
          17.times { |i| list.append(core.bytes("value #{i}")) }
        end
        old = Core::ArrayList.new(core.root_cursor).cursor_at(-1)
        core.transaction { |root| Core::ArrayList.new(root).put(-1, core.bytes("changed")) }

        assert_equal "value 16", old.read_bytes.bytes
        assert_raises(XitDB::ReadOnlyError) { old.replace(Core::Slot.null) }
      end
      assert_raises(XitDB::ClosedError) { old.slot }
      Core::Database.open(path, readonly: true) do |core|
        list = Core::ArrayList.new(core.root_cursor)

        assert_equal 17, list.size
        assert_equal "changed", list.cursor_at(-1).read_bytes.bytes
      end
    end
  end

  def test_failed_mutation_restores_state_and_releases_operation_checkpoints
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    core.transaction do |root|
      list = Core::ArrayList.new(root)
      list.append(Core::Slot.uint(1))
      child = list.cursor_at(0)
      length = root.transaction.length
      store.fault = ->(name, _args) { raise IOError, "allocation failed" if name == :append }
      assert_raises(IOError) { list.append(Core::Slot.uint(2)) }
      store.fault = nil

      assert_equal length, root.transaction.length
      assert_equal 1, list.size
      assert_equal 1, child.slot.value
      list.append(Core::Slot.uint(3))

      assert_empty root.transaction.instance_variable_get(:@checkpoints)
    end
  ensure
    store.fault = nil if store
  end

  def test_malformed_headers_and_blocks_respect_read_boundary
    Core::Database.memory.transaction do |root|
      tx = root.transaction
      pointer = tx.append([1, (1 << 64) - 1].pack("Q>Q>"))
      root.replace(Core::Slot.new(tag: :array_list, value: pointer))
      assert_raises(XitDB::CorruptionError) { Core::ArrayList.new(root).get(0) }
      root.replace(Core::Slot.uint(1))
      assert_raises(XitDB::InvalidValueError) { Core::ArrayList.new(root) }
    end
  end

  def test_nested_path_reads_do_not_repeat_ancestor_traversal_exponentially
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    core.transaction do |root|
      value = Core::Slot.uint(7)
      6.times do
        detached = root.transaction.cursor(slot: Core::Slot.new)
        Core::ArrayList.new(detached).append(value)
        value = detached.slot
      end
      root.replace(value)
    end
    reads = 0
    store.fault = ->(name, _args) { reads += 1 if name == :read_at }
    current = core.root_cursor
    6.times { current = current.child(kind: :array_list, selector: 0) }

    assert_equal 7, current.slot.value
    assert_operator reads, :<, 2_000
  end

  def test_sparse_branches_preserve_positions_during_iteration
    core = Core::Database.memory
    core.transaction do |root|
      tx = root.transaction
      leaf = tx.append(Core::Slot.uint(256).to_bytes + ("\0" * 135))
      branch = tx.append(Core::Slot.new(tag: :index, value: leaf).to_bytes + ("\0" * 135))
      top = tx.append(("\0" * 9) + Core::Slot.new(tag: :index, value: branch).to_bytes + ("\0" * 126))
      header = tx.append([257, top].pack("Q>Q>"))
      root.replace(Core::Slot.new(tag: :array_list, value: header))
    end
    list = Core::ArrayList.new(core.root_cursor)

    assert_empty list.get(0)
    assert_empty list.get(255)
    assert_equal 256, list.get(256).value
    assert_equal 257, list.each.count
    assert_equal 256, list.each.count(&:empty?)
    core.transaction do |root|
      writable = Core::ArrayList.new(root)
      writable.put(15, Core::Slot.null)

      assert writable.get(15).full
      writable.truncate(16)

      assert_equal 16, writable.size
    end
    assert_empty list.get(15)
  end

  def test_dead_children_release_their_cache_entries
    Core::Database.memory.transaction do |root|
      list = Core::ArrayList.new(root)
      200.times { |index| list.append(Core::Slot.uint(index)) }
      # Discard the creation stack before testing weak ownership.
      references = Fiber.new { Array.new(200) { |index| WeakRef.new(list.cursor_at(index)) } }.resume
      3.times { GC.start }

      assert_equal 0, references.count(&:weakref_alive?)
      assert_equal 0, root.instance_variable_get(:@children).size
      assert_empty root.transaction.instance_variable_get(:@checkpoints)
      assert_equal 199, list.get(-1).value
    end
  end
end
