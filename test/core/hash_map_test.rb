# frozen_string_literal: true

require "test_helper"
require "weakref"
require "tmpdir"
require_relative "../support/fault_store"

class HashMapTest < Minitest::Test
  Core = XitDB::Core

  def test_shared_hash_prefixes_and_exact_counts
    first_hash = ["1#{"a" * 39}"].pack("H*")
    second_hash = ["2#{"a" * 39}"].pack("H*")
    core = Core::Database.memory
    core.transaction do |root|
      map = Core::HashMap.new(root, counted: true)
      map.put(first_hash, key: Core::Slot.uint(1), value: Core::Slot.uint(7))
      map.put(second_hash, key: Core::Slot.uint(2), value: Core::Slot.uint(8))
      assert_equal 2, map.size
      assert_equal 7, map.get(first_hash).value
      assert map.remove(first_hash)
      assert_equal 1, map.size
      assert_equal 8, map.get(second_hash).value
      refute map.remove(first_hash)
    end
  end

  def test_all_collection_tags_preserve_empty_values_and_raw_keys
    [Core::HashMap, Core::HashSet, Core::CountedHashMap, Core::CountedHashSet].zip(
      %i[hash_map hash_set counted_hash_map counted_hash_set]
    ).each do |klass, tag|
      core = Core::Database.memory
      core.transaction do |root|
        map = klass.new(root)
        assert_equal tag, root.slot.tag
        assert_equal 0, map.size
        map.add(hash(1), key: Core::Slot.int(-1))
        map.put(hash(2), key: Core::Slot.float(-0.0), value: Core::Slot.null)
        map.put(hash(1), key: Core::Slot.uint(999), value: Core::Slot.uint(7))
        map.add(hash(3), key: Core::Slot.null)
        assert_equal 3, map.size
        assert_equal (1 << 64) - 1, map.key(hash(1)).value
        assert_equal 1 << 63, map.key(hash(2)).value
        assert map.get(hash(2)).full
        assert map.get(hash(3)).empty?
        assert map.include?(hash(3))
        refute map.include?(hash(4))
        assert_nil map.get(hash(4))
        assert_nil map.key(hash(4))
        assert_equal [1, 2, 3], map.each_entry.map { |h, _k, _v| h.unpack1("H*").to_i(16) }.sort
        assert map.remove(hash(3))
        assert_equal 2, map.size
        assert_empty root.transaction.instance_variable_get(:@checkpoints)
      end
      reader = klass.new(core.root_cursor)
      assert_equal 2, reader.size
      assert_raises(XitDB::ReadOnlyError) { reader.remove(hash(90)) }
      assert_raises(XitDB::ReadOnlyError) { reader.add(hash(90), key: Core::Slot.uint(90)) }
    end
  end

  def test_hash_children_propagate_through_arrays_and_removal_expires_aliases
    core = Core::Database.memory
    retained = nil
    core.transaction do |root|
      outer = Core::ArrayList.new(root)
      outer.append(Core::Slot.new)
      map = Core::CountedHashMap.new(outer.cursor_at(0))
      child = map.cursor_at(hash(7), create: true)
      retained = child
      list = Core::ArrayList.new(child)
      list.append(Core::Slot.uint(11))
      alias_child = root.child(kind: :array_list, selector: 0).child(kind: :hash_map, selector: hash(7))
      assert_same child, alias_child
      root.transaction.freeze
      list.append(Core::Slot.uint(12))
      assert_equal [11, 12], Core::ArrayList.new(alias_child).map(&:value)
      map.put(hash(8), key: Core::Slot.uint(8), value: Core::Slot.uint(8))
      assert_equal 2, list.size
      descendant = list.cursor_at(0)
      checkpoint = root.transaction.checkpoint
      map.remove(hash(7))
      assert_raises(XitDB::ExpiredViewError) { descendant.slot }
      root.transaction.restore(checkpoint)
      assert_equal 11, descendant.slot.value
      assert_equal 2, map.size
      map.put(hash(7), key: Core::Slot.uint(7), value: Core::Slot.uint(99))
      assert_raises(XitDB::ExpiredViewError) { alias_child.slot }
    end
    assert_raises(XitDB::ExpiredViewError) { retained.slot }
    assert_equal 99, Core::HashMap.from_cursor(Core::ArrayList.new(core.root_cursor).cursor_at(0)).get(hash(7)).value
  end

  def test_nested_hash_updates_restore_and_preserve_old_roots
    core = Core::Database.memory
    core.transaction do |root|
      map = Core::HashMap.new(root)
      nested = Core::HashSet.new(map.cursor_at(hash(1), create: true))
      nested.add(hash(2), key: Core::Slot.uint(2))
    end
    old = core.root_cursor
    core.transaction do |root|
      nested_cursor = Core::HashMap.new(root).cursor_at(hash(1))
      map = Core::HashSet.new(nested_cursor)
      checkpoint = root.transaction.checkpoint
      map.add(hash(3), key: Core::Slot.uint(3))
      created = map.cursor_at(hash(3))
      root.transaction.restore(checkpoint)
      assert_raises(XitDB::ExpiredViewError) { created.slot }
      assert_equal 1, map.size
      map.add(hash(4), key: Core::Slot.uint(4))
    end
    assert_equal 1, Core::HashSet.new(Core::HashMap.new(old).cursor_at(hash(1))).size
    assert_equal 2, Core::HashSet.new(Core::HashMap.new(core.root_cursor).cursor_at(hash(1))).size
  end

  def test_missing_reads_never_initialize_a_parent
    core = Core::Database.memory
    original_size = core.committed_size
    assert_equal 0, Core::HashMap.new(core.root_cursor).size
    assert_equal original_size, core.committed_size
    core.transaction do |root|
      length = root.transaction.length
      assert_nil root.child(kind: :hash_map, selector: hash(1))
      assert_nil root.child(kind: :hash_set, selector: hash(1))
      assert root.slot.empty?
      assert_equal length, root.transaction.length
    end
  end

  def test_invalid_hashes_and_internal_slots_leave_state_unchanged
    Core::Database.memory.transaction do |root|
      map = Core::HashMap.new(root)
      length = root.transaction.length
      ["", "a" * 19, "a" * 21, "é" * 20].each do |bad|
        assert_raises(ArgumentError) { map.put(bad, key: Core::Slot.uint(1), value: Core::Slot.uint(1)) }
        assert_raises(ArgumentError) { map.get(bad) }
        assert_raises(ArgumentError) { map.remove(bad) }
      end
      assert_raises(TypeError) { map.get(nil) }
      assert_raises(TypeError) { map.put(hash(1), key: nil, value: Core::Slot.uint(1)) }
      assert_raises(XitDB::InvalidValueError) { map.add(hash(1), key: Core::Slot.new(tag: :index)) }
      assert_equal length, root.transaction.length
      assert_equal 0, map.size
      root.replace(Core::Slot.uint(1))
      assert_raises(XitDB::InvalidValueError) { Core::HashMap.new(root) }
    end
  end

  def test_raw_hash_identity_uses_bytes_in_every_string_encoding
    Core::Database.memory.transaction do |root|
      map = Core::CountedHashMap.new(root)
      utf8_hash = "é" * 10
      map.put(utf8_hash, key: Core::Slot.uint(1), value: Core::Slot.uint(7))
      assert map.include?(utf8_hash)
      assert_equal 7, map.get(utf8_hash.b).value
      map.put(utf8_hash.b, key: Core::Slot.uint(2), value: Core::Slot.uint(8))
      assert_equal 1, map.size
      assert_equal 8, map.get(utf8_hash).value
      child = map.cursor_at(utf8_hash)
      child.replace(Core::Slot.uint(9))
      assert_equal 9, map.get(utf8_hash.b).value
      assert map.remove(utf8_hash)
      assert_equal 0, map.size
    end
  end

  def test_configured_hash_width_controls_the_deepest_split
    [[1, "test"], [32, "sha2"]].each do |width, id|
      core = Core::Database.memory(hash_size: width, hash_id: id)
      first = ["1#{"a" * ((width * 2) - 1)}"].pack("H*")
      second = ["2#{"a" * ((width * 2) - 1)}"].pack("H*")
      core.transaction do |root|
        map = Core::CountedHashMap.new(root)
        map.put(first, key: Core::Slot.uint(1), value: Core::Slot.uint(7))
        map.put(second, key: Core::Slot.uint(2), value: Core::Slot.uint(8))
        assert_equal 2, map.size
        assert_equal 7, map.get(first).value
        assert_equal 8, map.get(second).value
        assert map.remove(first)
        assert_equal 8, map.get(second).value
      end
    end
  end

  def test_many_shared_branches_collapse_after_removal_without_changing_snapshots
    core = Core::Database.memory
    hashes = 100.times.map { |i| [format("%04x", i) + ("a" * 36)].pack("H*") }
    core.transaction do |root|
      map = Core::CountedHashMap.new(root)
      hashes.each_with_index { |h, i| map.put(h, key: Core::Slot.uint(i), value: Core::Slot.uint(i + 1)) }
    end
    old = Core::CountedHashMap.new(core.root_cursor)
    core.transaction do |root|
      map = Core::CountedHashMap.new(root)
      hashes.each_with_index do |h, i|
        assert_equal i + 1, map.get(h).value
        assert map.remove(h)
        assert_equal 99 - i, map.size
      end
      assert_empty map.each_entry.to_a
    end
    assert_equal 100, old.size
    assert_equal 100, old.each_entry.count
    assert_equal 1, old.get(hashes.first).value
    assert_equal 100, old.get(hashes.last).value
  end

  def test_failed_mutation_restores_allocation_and_live_views
    store = FaultStore.new(Core::MemoryStore.new)
    core = Core::Database.new(store: store)
    core.transaction do |root|
      map = Core::CountedHashMap.new(root)
      map.put(hash(1), key: Core::Slot.uint(1), value: Core::Slot.uint(7))
      child = map.cursor_at(hash(1))
      original = root.slot.to_bytes
      length = root.transaction.length
      store.fault = lambda do |name, _args|
        if name == :write_at
          store.fault = nil
          raise IOError, "injected hash write failure"
        end
      end
      assert_raises(IOError) { map.put(hash(2), key: Core::Slot.uint(2), value: Core::Slot.uint(8)) }
      assert_equal original, root.slot.to_bytes
      assert_equal length, root.transaction.length
      assert_equal 7, child.slot.value
      assert_equal 1, map.size
      assert_empty root.transaction.instance_variable_get(:@checkpoints)
    end
  end

  def test_corrupt_branches_records_and_captured_bounds_fail
    core = Core::Database.memory
    core.transaction do |root|
      tx = root.transaction
      block = tx.append(Core::Slot.new(tag: :index, value: tx.length).to_bytes + ("\0" * 135))
      root.replace(Core::Slot.new(tag: :hash_map, value: block))
      assert_raises(XitDB::CorruptionError) { Core::HashMap.new(root).get(hash(0)) }
      assert_raises(XitDB::CorruptionError) { Core::HashMap.new(root).each_entry.to_a }
      block = tx.append(Core::Slot.uint(1).to_bytes + ("\0" * 135))
      root.replace(Core::Slot.new(tag: :hash_map, value: block))
      assert_raises(XitDB::CorruptionError) { Core::HashMap.new(root).get(hash(0)) }
      root.replace(Core::Slot.new)
      map = Core::HashMap.new(root)
      map.put(hash(0), key: Core::Slot.uint(1), value: Core::Slot.uint(1))
      short_reader = Core::Cursor.new(database: core, slot: root.slot, bound: root.slot.value + 144)
      assert_raises(XitDB::CorruptionError) { Core::HashMap.new(short_reader).get(hash(0)) }
    end
  end

  def test_empty_physical_types_survive_reopening
    Dir.mktmpdir do |dir|
      [Core::HashMap, Core::HashSet, Core::CountedHashMap, Core::CountedHashSet].each do |klass|
        path = File.join(dir, "#{klass.name.split("::").last}.xit")
        Core::Database.open(path) { |db| db.transaction { |root| klass.new(root) } }
        Core::Database.open(path, readonly: true) do |db|
          refute db.root_cursor.slot.empty?
          assert_equal 0, klass.new(db.root_cursor).size
        end
      end
    end
  end

  def test_transient_hash_children_are_reclaimed
    Core::Database.memory.transaction do |root|
      map = Core::HashMap.new(root)
      100.times { |i| map.add(hash(i), key: Core::Slot.uint(i)) }
      references = 100.times.map { |i| WeakRef.new(map.cursor_at(hash(i))) }
      3.times { GC.start }
      assert_equal 0, references.count(&:weakref_alive?)
      assert_equal 0, root.instance_variable_get(:@children).size
      assert_empty root.transaction.instance_variable_get(:@checkpoints)
    end
  end

  private

  def hash(number)
    [format("%040x", number)].pack("H*")
  end
end
