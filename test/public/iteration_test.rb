# frozen_string_literal: true

require "test_helper"
require "objspace"
require "xitdb/ruby"

class PublicIterationTest < Minitest::Test
  def setup
    @db = XitDB.memory
  end

  def teardown
    @db.close unless @db.closed?
  end

  def test_shifted_descendants_expire_while_earlier_locations_remain_live
    [XitDB.array, XitDB.linked_array].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"].push([0], { "child" => [1] }, [2])
        prefix = items[0]
        shifted = items[1]["child"]
        tail = items[2]
        iterator = items.each
        iterator.next
        items.insert(1, [9])
        assert_raises(XitDB::ExpiredViewError) { shifted << 5 }
        assert_raises(XitDB::ExpiredViewError) { tail.size }
        assert_raises(XitDB::ConcurrentModificationError) { iterator.next }
        prefix << 4
        current = items[2]["child"]
        current << 6
        assert_equal [[0, 4], [9], { "child" => [1, 6] }, [2]], items.to_ruby
        items.delete_at(1)
        assert_raises(XitDB::ExpiredViewError) { current.size }
        assert_equal [0, 4], prefix.to_ruby
        assert_equal [1, 6], items[1]["child"].to_ruby
      end
    end
  end

  def test_linked_shifts_retain_metadata_only_for_observed_locations
    @db.transaction do |root|
      root["items"] = XitDB.linked_array
      items = root["items"].concat(Array.new(4097) { [1] })
      tail = items[4096]
      before = retained_context_bytes(items.context)
      items.insert(0, [9])
      assert_raises(XitDB::ExpiredViewError) { tail.size }
      assert_operator retained_context_bytes(items.context) - before, :<, 4096
      current = items[4097]
      items.delete_at(0)
      assert_raises(XitDB::ExpiredViewError) { current.size }
      assert_operator retained_context_bytes(items.context) - before, :<, 4096
      assert_equal [1], items[4096].to_ruby
    end
  end

  def test_transaction_iteration_yields_writable_children_and_live_replacements
    [XitDB.map, XitDB.map(counted: true), XitDB.sorted_map].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"].merge!({ "a" => [1], "b" => [2], "c" => [3] })
        items.each_value { |child| child << 4 }
        assert_equal [[1, 4], [2, 4], [3, 4]], items.values.map(&:to_ruby).sort
        order = items.keys
        iterator = items.each_value
        iterator.next
        items[order[1]] = [9]
        assert_equal [9], iterator.next.to_ruby
        items.delete(order[2])
        assert_raises(XitDB::ConcurrentModificationError) { iterator.next }
      end
    end
  end

  def test_snapshot_traversal_retains_no_per_position_generation_metadata
    @db.transaction { |root| root["items"] = Array.new(1024) { [1] } }
    items = @db.snapshot["items"]
    before = retained_context_bytes(items.context)
    items.each(&:size)
    GC.start
    assert_operator retained_context_bytes(items.context) - before, :<, 4096
  end

  def test_key_enumeration_does_not_read_large_values_and_keeps_lifetime_checks
    configurations = [[XitDB, [XitDB.map, XitDB.map(counted: true), XitDB.sorted_map]],
                      [XitDB::Ruby, [XitDB.map, XitDB.sorted_map(key: :string)]]]
    configurations.each do |api, declarations|
      declarations.each do |declaration|
        api.memory do |db|
          items = nil
          db.transaction do |root|
            root["items"] = declaration
            items = root["items"].merge!({ "a" => "v" * 100_000, "b" => "w" * 100_000 })
            forbidden = items.adapter.each_entry.map { |_key, slot| slot.value + 8 }
            store = db.core.instance_variable_get(:@store)
            original = store.method(:read_at)
            store.define_singleton_method(:read_at) do |offset, length|
              raise "value payload read" if forbidden.any? { |start| offset <= start && offset + length > start }

              original.call(offset, length)
            end
            assert_equal %w[a b], items.keys.sort
            assert_equal %w[a b], items.each_key.to_a.sort
            iterator = items.each_key
            iterator.next
            items["c"] = 1
            assert_raises(XitDB::ConcurrentModificationError) { iterator.next }
            iterator = items.each_key
            iterator.next
            root["items"] = {}
            assert_raises(XitDB::ExpiredViewError) { iterator.next }
            store.singleton_class.remove_method(:read_at)
          end
          assert_raises(XitDB::ExpiredViewError) { items.each_key.to_a }
          snapshot = db.snapshot
          db.close
          assert_raises(XitDB::ClosedError) { snapshot.keys }
          assert_raises(XitDB::ClosedError) { snapshot.each_key.to_a }
        end
      end
    end
  end

  def test_dropped_transaction_children_release_generation_metadata
    @db.transaction do |root|
      root["items"] = Array.new(1024) { [1] }
      items = root["items"]
      before = retained_context_bytes(items.context)
      items.each(&:size)
      GC.start
      items << [2]
      assert_operator retained_context_bytes(items.context) - before, :<, 4096
    end
  end

  def test_replacing_an_ancestor_expires_descendants_and_iterators
    @db.transaction do |root|
      root["parent"] = { "items" => [[1], [2]] }
      items = root["parent"]["items"]
      child = items[0]
      iterator = items.each
      iterator.next
      root["parent"] = { "items" => [[3], [4]] }
      assert_raises(XitDB::ExpiredViewError) { child.to_ruby }
      assert_raises(XitDB::ExpiredViewError) { iterator.next }
      assert_equal [[3], [4]], root["parent"]["items"].to_ruby
    end
  end

  def test_byte_equal_map_keys_share_child_lifetime_across_encodings
    [XitDB.map, XitDB.map(counted: true), XitDB.sorted_map].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"]
        items["é"] = { "child" => [1] }
        child = items["é".b]["child"]
        items["é"] = { "child" => [2] }
        assert_raises(XitDB::ExpiredViewError) { child.size }
        child = items["é"]["child"]
        items.delete("é".b)
        assert_raises(XitDB::ExpiredViewError) { child.size }
        assert_empty items
      end
    end
  end

  def test_set_membership_invalidates_iterators_but_noops_preserve_them
    [XitDB.set, XitDB.set(counted: true), XitDB.sorted_set].each do |declaration|
      @db.transaction do |root|
        root["items"] = declaration
        items = root["items"].add("a").add("b").add("c")
        iterator = items.each
        first = iterator.next
        items.add(first).delete("missing")
        assert_kind_of String, iterator.next
        items.add("d")
        assert_raises(XitDB::ConcurrentModificationError) { iterator.next }
      end
    end
  end

  private

  def retained_context_bytes(context)
    ObjectSpace.reachable_objects_from(context).sum { |object| ObjectSpace.memsize_of(object) }
  end
end
