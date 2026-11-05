# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "weakref"
require_relative "../support/fault_store"

class SortedMapTest < Minitest::Test
  Core = XitDB::Core

  def test_reference_records_store_key_before_value
    Core::Database.memory.transaction do |root|
      tx = root.transaction
      key = Core::Slot.new(tag: :short_bytes, value: 0x6100000000000000)
      pair = tx.append(key.to_bytes + Core::Slot.uint(7).to_bytes)
      entry = Core::Slot.new(tag: :sorted_kv_pair, value: pair)
      leaf = tx.append([0, 1].pack("CC") + entry.to_bytes + ("\0" * 135))
      header = tx.append([1, leaf].pack("Q>Q>"))
      root.replace(Core::Slot.new(tag: :sorted_map, value: header))
      map = Core::SortedMap.new(root)

      assert_equal 7, map.get("a").value
      map.put("b", value: Core::Slot.uint(8))
      leaf_pointer = db_read(root, root.slot.value + 8, 8).unpack1("Q>")
      stored = Core::Slot.parse(db_read(root, leaf_pointer + 11, 9))

      assert_equal "6200000000000000", db_read(root, stored.value + 1, 8).unpack1("H*")
      assert_equal Core::Slot.uint(8), Core::Slot.parse(db_read(root, stored.value + 9, 9))
    end
  end

  def test_byte_order_rank_and_prefix_seek
    Core::Database.memory.transaction do |root|
      index = Core::SortedMap.new(root)
      %w[c a b].each_with_index { |key, i| index.put(key, value: Core::Slot.uint(i)) }

      assert_equal 1, index.rank("b")
      assert_equal %w[b c], index.each_from("b").map(&:first)
      assert_equal "c", index.at(-1).first
      ["", "\0", "a\0", "é", "\xff".b].each { |key| index.put(key, value: Core::Slot.null) }

      assert_equal ["", "\0", "a", "a\0", "b", "c", "é".b, "\xff".b], index.map(&:first)
      assert_equal 4, index.rank("az")
      assert_equal ["b", "c", "é".b, "\xff".b], index.each_from("az").map(&:first)
      assert_equal ["é".b, "\xff".b], index.each_from_index(-2).map(&:first)
      assert_nil index.at(8)
      assert_nil index.get("missing")
    end
  end

  def test_sets_keep_key_only_members_and_maps_can_replace_them
    Core::Database.memory.transaction do |root|
      set = Core::SortedSet.new(root)
      ["", "a\0", "é", "long-key-with-bytes"].each { |key| set.add(key) }

      assert_equal :sorted_set, root.slot.tag
      assert_equal 4, set.size
      assert_includes set, "é".b
      assert_empty set.get("é")
      set.add("é".b)

      assert_equal 4, set.size
      map = Core::SortedMap.new(root)
      map.put("é", value: Core::Slot.uint(7))
      set.add("é")

      assert_equal 7, map.get("é".b).value
      assert map.remove("a\0")
      refute map.remove("a\0")
      assert_equal 3, map.size
      refute_includes map, "a\0"
    end
  end

  def test_seeded_edits_counts_empty_leaves_and_old_roots
    db = Core::Database.memory
    keys = Array.new(513) { |i| format("k%04d", i) }
    db.transaction do |root|
      map = Core::SortedMap.new(root)
      keys.shuffle(random: Random.new(8)).each_with_index do |key, i|
        map.put(key, value: Core::Slot.uint(key.delete_prefix("k").to_i))

        assert_equal i + 1, map.size
      end
    end
    old = Core::SortedMap.new(db.root_cursor)
    db.transaction do |root|
      map = Core::SortedMap.new(root)
      keys.shuffle(random: Random.new(9)).each_with_index do |key, i|
        assert map.remove(key)
        assert_equal 512 - i, map.size
        assert_equal 0, map.rank(key) if i == 512
      end

      assert_empty map.to_a
      keys.reverse_each { |key| map.put(key, value: Core::Slot.uint(99)) }

      assert_equal keys, map.map(&:first)
      keys.each_with_index { |key, i| assert_equal i, map.rank(key) }
    end

    assert_equal 513, old.size
    assert_equal 512, old.at(-1).last.value
  end

  def test_nested_children_keep_identity_and_restore_after_failed_updates
    store = FaultStore.new(Core::MemoryStore.new)
    db = Core::Database.new(store: store)
    db.transaction do |root|
      outer = Core::ArrayList.new(root)
      outer.append(Core::Slot.new)
      map_cursor = outer.cursor_at(0)
      map = Core::SortedMap.new(map_cursor)
      child = map.cursor_at("b", create: true)
      list = Core::ArrayList.new(child)
      list.append(Core::Slot.uint(1))

      assert_same child, map_cursor.child(kind: :sorted_map, selector: "b")
      map.put("a", value: Core::Slot.uint(2))
      root.transaction.freeze
      list.append(Core::Slot.uint(3))

      assert_equal [1, 3], Core::ArrayList.new(child).map(&:value)
      checkpoint = root.transaction.checkpoint
      map.remove("b")
      assert_raises(XitDB::ExpiredViewError) { child.slot }
      root.transaction.restore(checkpoint)

      assert_equal 2, list.size
      length = root.transaction.length
      store.fault = lambda do |name, _args|
        next unless name == :write_at

        store.fault = nil
        raise IOError, "injected sorted write failure"
      end
      assert_raises(IOError) { map.put("c", value: Core::Slot.uint(4)) }
      assert_equal length, root.transaction.length
      assert_equal 2, map.size
      assert_equal 2, list.size
      map.put("b", value: Core::Slot.uint(5))
      assert_raises(XitDB::ExpiredViewError) { child.slot }
      assert_empty root.transaction.instance_variable_get(:@checkpoints)
    end
  end

  def test_tail_seek_reads_only_a_bounded_path
    store = FaultStore.new(Core::MemoryStore.new)
    db = Core::Database.new(store: store)
    db.transaction do |root|
      map = Core::SortedMap.new(root)
      4097.times { |i| map.put(format("%08d", i), value: Core::Slot.uint(i)) }
    end
    map = Core::SortedMap.new(db.root_cursor)
    store.events.clear

    assert_equal([4095, 4096], map.each_from("00004095").map { |_key, slot| slot.value })
    assert_operator store.events.count { |name, _| name == :read_at }, :<, 100
    store.events.clear

    assert_equal([4095, 4096], map.each_from_index(4095).map { |_key, slot| slot.value })
    assert_operator store.events.count { |name, _| name == :read_at }, :<, 30
  end

  def test_sorted_children_propagate_through_hashes_and_sorted_parents
    db = Core::Database.memory
    retained = nil
    db.transaction do |root|
      map = Core::SortedMap.new(root)
      hash = Core::HashMap.new(map.cursor_at("hash", create: true))
      key = "\x01" * 20
      nested = Core::SortedSet.new(hash.cursor_at(key, create: true))
      nested.add("a")
      retained = nested.cursor
      root.transaction.freeze
      nested.add("b")

      assert_equal %w[a b], nested.map(&:first)
      assert_equal 1, map.size
      assert_same nested.cursor, map.cursor_at("hash").child(kind: :hash_map, selector: key)
      nested.add("c")
      transient = WeakRef.new(nested.cursor_at("c"))
      3.times { GC.start }

      refute_predicate transient, :weakref_alive?
    end
    assert_raises(XitDB::ExpiredViewError) { retained.slot }
    reader = Core::SortedMap.new(db.root_cursor)
    nested_cursor = Core::HashMap.new(reader.cursor_at("hash")).cursor_at("\x01" * 20)

    assert_equal %w[a b c], Core::SortedSet.new(nested_cursor).map(&:first)
  end

  def test_malformed_nodes_records_cycles_and_captured_bounds_fail
    Core::Database.memory.transaction do |root|
      tx = root.transaction
      map = Core::SortedMap.new(root)
      map.put("long-key-with-bytes", value: Core::Slot.uint(1))
      reader = Core::Cursor.new(database: root.database, slot: root.slot, bound: root.slot.value + 8)
      assert_raises(XitDB::CorruptionError) { Core::SortedMap.new(reader).size }
      pointer = db_read(root, root.slot.value + 8, 8).unpack1("Q>")
      tx.write_at(pointer + 2, Core::Slot.uint(1).to_bytes)
      assert_raises(XitDB::CorruptionError) { map.at(0) }
      cycle = tx.length
      branch = [1, 1].pack("CC") + Core::Slot.new(tag: :index, value: cycle).to_bytes + ("\0" * 279)
      branch << ([1] + ([0] * 15)).pack("Q>*")
      tx.append(branch)
      header = tx.append([1, cycle].pack("Q>Q>"))
      root.replace(Core::Slot.new(tag: :sorted_map, value: header))
      assert_raises(XitDB::CorruptionError) { map.get("a") }
      assert_raises(XitDB::CorruptionError) { map.at(0) }
      record = tx.append(Core::Slot.uint(1).to_bytes + Core::Slot.uint(2).to_bytes)
      leaf = tx.append([0, 1].pack("CC") + Core::Slot.new(tag: :sorted_kv_pair, value: record).to_bytes + ("\0" * 135))
      header = tx.append([1, leaf].pack("Q>Q>"))
      root.replace(Core::Slot.new(tag: :sorted_map, value: header))
      assert_raises(XitDB::CorruptionError) { map.get("a") }
    end
  end

  def test_empty_types_read_only_and_invalid_inputs
    Dir.mktmpdir do |dir|
      [Core::SortedMap, Core::SortedSet].each do |klass|
        path = File.join(dir, klass.name.split("::").last)
        Core::Database.open(path) { |db| db.transaction { |root| klass.new(root) } }
        Core::Database.open(path, readonly: true) do |db|
          map = klass.new(db.root_cursor)

          assert_equal 0, map.size
          refute_empty db.root_cursor.slot
          assert_raises(XitDB::ReadOnlyError) { map.remove("missing") }
          assert_raises(XitDB::ReadOnlyError) { map.put("a", value: Core::Slot.uint(1)) }
        end
      end
    end
    db = Core::Database.memory

    assert_nil db.root_cursor.child(kind: :sorted_map, selector: "a")
    assert_equal 0, Core::SortedMap.new(db.root_cursor).size
    assert_empty db.root_cursor.slot
    db.transaction do |root|
      map = Core::SortedMap.new(root)
      length = root.transaction.length
      assert_raises(TypeError) { map.get(nil) }
      assert_raises(TypeError) { map.put("a", value: nil) }
      assert_raises(XitDB::InvalidValueError) { map.put("a", value: Core::Slot.new(tag: :index)) }
      assert_raises(TypeError) { map.at(1.0) }
      assert_equal length, root.transaction.length
    end
  end

  private

  def db_read(cursor, offset, length)
    cursor.database.read_at(offset, length, bound: cursor.bound)
  end
end
