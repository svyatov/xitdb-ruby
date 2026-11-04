# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "set"

class PublicDatabaseTest < Minitest::Test
  def setup
    @db = XitDB.memory
  end

  def teardown
    @db&.close unless @db&.closed?
  end

  def test_snapshot_history_revert_and_block_exits
    assert_nil @db.snapshot.revision
    assert_empty @db.snapshot
    assert_equal 0, @db.history.size
    @db.transaction { |root| root["visits"] = 0 }
    before = @db.snapshot
    after = @db.transaction { |root| root["visits"] += 1 }
    assert_equal [0, 1], [before["visits"], after["visits"]]
    assert_equal 0, @db.revert(before)["visits"]
    assert_equal [0, 1, 0], @db.history.map { |snapshot| snapshot["visits"] }
    assert_equal 1, @db.history[-2]["visits"]
    assert_nil @db.history[3]
    assert_raises(IndexError) { @db.history.fetch(-4) }
    assert_equal 0, @db.snapshot(revision: before.revision)["visits"]
    assert before.revision.frozen?
    size = @db.history.size
    assert_equal 0, @db.transaction { |_root| next 42 }["visits"]
    assert_equal size, @db.history.size
    assert_equal :exit, @db.transaction { |root| root["visits"] = 7; break :exit }
    assert_equal :thrown, catch(:abort) { @db.transaction { |root| root["visits"] = 8; throw :abort, :thrown } }
    assert_equal :returned, return_from_transaction
    failure = RuntimeError.new("application error")
    assert_same failure, assert_raises(RuntimeError) { @db.transaction { |root| root["visits"] = 9; raise failure } }
    assert_equal size, @db.history.size
    assert_equal 0, @db.snapshot["visits"]
  end

  def test_map_reads_mutations_and_materialization
    snapshot = @db.transaction do |root|
      root["profile"] = {"name" => "Ada", "visits" => 0}
      root["nil"] = nil
      assert root.key?("nil")
      assert_nil root["missing"]
      assert_equal :default, root.fetch("missing", :default)
      assert_equal "MISSING", root.fetch("missing", :ignored) { |key| key.upcase }
      assert_raises(KeyError) { root.fetch("missing") }
      assert_nil root.dig("missing", "child")
      assert_raises(TypeError) { root.dig("profile", "visits", "child") }
      root["profile"].merge!({"visits" => 1, "city" => "Paris"})
      assert_equal "Paris", root["profile"].delete("city")
      assert_equal "absent", root.delete("absent") { |key| key }
      root["temporary"] = {"a" => 1}
      root["temporary"].clear
    end
    assert_equal "Ada", snapshot.dig("profile", "name")
    assert_equal ["nil", "profile", "temporary"], snapshot.keys.sort
    assert_equal snapshot.keys, snapshot.each_key.to_a
    assert_equal snapshot.values, snapshot.each_value.to_a
    assert_equal 3, snapshot.size
    assert snapshot["profile"]["name"].frozen?
    ruby = snapshot.to_ruby
    ruby["profile"]["name"] << " Smith"
    assert_equal "Ada", snapshot.dig("profile", "name")
    assert_equal({"profile" => {"name" => "Ada", "visits" => 1}, "nil" => nil, "temporary" => {}}, snapshot.to_ruby)
    assert_raises(XitDB::ReadOnlyError) { snapshot["a"] = 1 }
    assert_raises(XitDB::ReadOnlyError) { snapshot.delete("absent") }
  end

  def test_atomic_inputs_and_value_ownership
    input = {"name" => +"Ada", "nested" => [1, {"x" => 2}]}
    @db.transaction do |root|
      root["data"] = input
      input["name"].replace("Changed")
      input["nested"] << 3
      assert_equal "Ada", root.dig("data", "name")
      assert_equal [1, {"x" => 2}], root["data"]["nested"].to_ruby
      root["copy"] = root["data"]
      root["data"]["name"] = "New"
      assert_equal "Ada", root.dig("copy", "name")
      old = root.to_ruby
      bad = [Hash.new(1), Hash.new { 1 }, {}.compare_by_identity, true, :symbol, Object.new]
      bad.each do |value|
        assert_raises(XitDB::UnsupportedValueError) { root["bad"] = value }
        assert_equal old, root.to_ruby
      end
      cyclic = []; cyclic << cyclic
      error = assert_raises(XitDB::CyclicValueError) { root["cycle"] = cyclic }
      assert_equal ["cycle", 0], error.path
      assert_equal old, root.to_ruby
      duplicate = {"é" => 1, "é".b => 2}
      assert_equal 2, duplicate.size
      assert_raises(XitDB::KeyCollisionError) { root["collision"] = duplicate }
      assert_raises(XitDB::KeyCollisionError) { root.merge!(duplicate) }
      assert_equal old, root.to_ruby
      assert_raises(XitDB::UnsupportedValueError) { root.merge!({"ok" => 1, "bad" => true}) }
      assert_equal old, root.to_ruby
    end
    XitDB.memory do |other|
      assert_raises(XitDB::ForeignValueError) { other.transaction { |root| root["foreign"] = @db.snapshot } }
    end
  end

  def test_assigning_a_virtual_empty_snapshot_captures_an_empty_map
    empty = @db.snapshot
    snapshot = @db.transaction { |root| root["copy"] = empty }
    assert_equal({}, snapshot["copy"].to_ruby)
    assert_empty empty
  end

  def test_view_lifetimes_and_committed_reads
    @db.transaction { |root| root["child"] = {"value" => 1} }
    snapshot = @db.snapshot
    expired = nil
    @db.transaction do |root|
      expired = root
      child = root["child"]
      child["value"] = 2
      assert_equal 2, child["value"]
      assert_equal 1, @db.snapshot.dig("child", "value")
      root["unrelated"] = 3
      assert_equal 2, child["value"]
      root["child"] = {"value" => 4}
      assert_raises(XitDB::ExpiredViewError) { child["value"] }
      assert_raises(XitDB::TransactionStateError) { @db.transaction {} }
      assert_raises(XitDB::TransactionStateError) { @db.close }
      error = Thread.new { root.size rescue $! }.value
      assert_instance_of XitDB::TransactionStateError, error
    end
    assert_raises(XitDB::ExpiredViewError) { expired.size }
    assert_equal 1, snapshot.dig("child", "value")
    @db.close
    assert_raises(XitDB::ClosedError) { snapshot.size }
  end

  def test_iterators_detect_membership_changes_but_allow_value_edits
    @db.transaction do |root|
      root.merge!({"a" => {"n" => 1}, "b" => {"n" => 2}})
      root.each { |_key, value| value["n"] += 10 }
      assert_equal [11, 12], root.values.map { |value| value["n"] }.sort
      iterator = root.each
      key, = iterator.next
      root[key] = 5
      iterator.next
      iterator = root.each
      iterator.next
      root["c"] = 3
      assert_raises(XitDB::ConcurrentModificationError) { iterator.next }
    end
  end

  def test_all_portable_containers_have_generic_reads
    @db.transaction do |root|
      root["array"] = [1, "two", {"three" => 3}]
      root["set"] = Set["a", "b"]
      root["counted"] = XitDB.map(counted: true)
      root["counted"]["n"] = 1
      [XitDB.array, XitDB.linked_array, XitDB.set(counted: true), XitDB.sorted_map, XitDB.sorted_set].each_with_index do |declaration, i|
        root[i.to_s] = declaration
        assert root[i.to_s].empty?
      end
    end
    snapshot = @db.snapshot
    assert_equal [1, "two", {"three" => 3}], snapshot["array"].to_ruby
    assert_equal [1, "two", {"three" => 3}], snapshot["array"].map { |v| v.respond_to?(:to_ruby) ? v.to_ruby : v }
    assert_equal Set["a", "b"], snapshot["set"].to_ruby
    assert_equal({"n" => 1}, snapshot["counted"].to_ruby)
    assert_equal 3, snapshot["array"].size
  end

  def test_file_opening_hashes_and_revision_identity
    Dir.mktmpdir do |dir|
      path = File.join(dir, "db.xit")
      assert_raises(Errno::ENOENT) { XitDB.open(path, readonly: true) }
      before = nil
      XitDB.open(path, hash: :sha256) do |db|
        before = db.transaction { |root| root["n"] = 1 }.revision
        db.transaction { |root| root["n"] = 2 }
      end
      XitDB.open(path, readonly: true) do |db|
        assert_equal 1, db.snapshot(revision: before)["n"]
        assert_equal 2, db.snapshot["n"]
        assert_raises(XitDB::ReadOnlyError) { db.transaction {} }
        assert_raises(XitDB::ReadOnlyError) { db.revert(before) }
      end
      assert_raises(XitDB::ForeignRevisionError) { @db.snapshot(revision: before) }
      bytes = File.binread(path)
      assert_raises(XitDB::ProfileMismatchError) { XitDB.open(path, hash: :sha1) }
      assert_equal bytes, File.binread(path)
      invalid = File.join(dir, "invalid.xit")
      File.binwrite(invalid, "invalid")
      assert_raises(XitDB::CorruptionError) { XitDB.open(invalid) }
      assert_equal "invalid", File.binread(invalid)
      custom = XitDB::Core::Hasher.new(id: "test", size: 20) { |value| Digest::SHA1.digest(value) }
      custom_path = File.join(dir, "custom.xit")
      XitDB.open(custom_path, hash: custom) { |db| db.transaction { |root| root["n"] = 3 } }
      bytes = File.binread(custom_path)
      assert_raises(XitDB::ProfileMismatchError) { XitDB.open(custom_path) }
      assert_equal bytes, File.binread(custom_path)
      XitDB.open(custom_path, hash: custom) { |db| assert_equal 3, db.snapshot["n"] }
      ruby_path = File.join(dir, "ruby.xit")
      XitDB::Core::Database.open(ruby_path, hash_id: "rb01", hash_size: 32).close
      assert_raises(XitDB::ProfileMismatchError) { XitDB.open(ruby_path) }
    end
  end

  def test_reserved_ruby_profile_identifier_is_rejected_before_creation
    hasher = XitDB::Core::Hasher.new(id: "rb01", size: 32) { |bytes| Digest::SHA256.digest(bytes) }
    assert_raises(XitDB::ProfileMismatchError) { XitDB.memory(hash: hasher) }
    Dir.mktmpdir do |dir|
      path = File.join(dir, "reserved.xit")
      assert_raises(XitDB::ProfileMismatchError) { XitDB.open(path, hash: hasher) }
      refute File.exist?(path)
    end
  end

  def test_existing_empty_file_is_rejected_unchanged_while_missing_path_is_created
    Dir.mktmpdir do |dir|
      empty_path = File.join(dir, "empty.xit")
      File.binwrite(empty_path, "")
      [false, true].each do |readonly|
        assert_raises(XitDB::CorruptionError) { XitDB.open(empty_path, readonly: readonly) }
        assert_equal 0, File.size(empty_path)
      end

      missing_path = File.join(dir, "created.xit")
      XitDB.open(missing_path) do |db|
        assert_empty db.snapshot
        db.transaction { |root| root["created"] = 1 }
      end
      XitDB.open(missing_path) { |db| assert_equal 1, db.snapshot["created"] }
      assert_equal 0, File.size(empty_path)
    end
  end

  def test_existing_path_removed_during_creation_fallback_is_not_recreated
    Dir.mktmpdir do |dir|
      path = File.join(dir, "removed.xit")
      File.binwrite(path, "")
      removed = false
      trace = TracePoint.new(:raise) do |event|
        if !removed && event.raised_exception.is_a?(Errno::EEXIST)
          File.unlink(path)
          removed = true
        end
      end
      assert_raises(Errno::ENOENT) { trace.enable { XitDB.open(path) } }
      assert removed
      refute File.exist?(path)
    ensure
      trace&.disable
    end
  end

  def test_restored_file_rejects_stale_proof_even_with_same_file_identity
    Dir.mktmpdir do |dir|
      path = File.join(dir, "db.xit")
      token = nil
      original = nil
      XitDB.open(path) do |db|
        db.transaction { |root| root["n"] = 1 }
        original = File.binread(path)
        token = db.transaction { |root| root["n"] = 2 }.revision
      end
      File.binwrite(path, original)
      XitDB.open(path) do |db|
        db.transaction { |root| root["n"] = 3 }
        assert_raises(XitDB::ForeignRevisionError) { db.snapshot(revision: token) }
        assert_raises(XitDB::ForeignRevisionError) { db.revert(token) }
        assert_equal [1, 3], db.history.map { |snapshot| snapshot["n"] }
      end
    end
  end

  def test_clear_keeps_collection_views_live_and_expires_children
    @db.transaction do |root|
      root["map"] = {"child" => {"n" => 1}}
      first = root["map"]
      second = root["map"]
      child = first["child"]
      first.clear
      assert_empty first
      assert_empty second
      assert_raises(XitDB::ExpiredViewError) { child.size }
      second["new"] = 2
      assert_equal 2, first["new"]
    end
  end

  def test_noop_and_failed_operations_do_not_create_a_revision
    @db.transaction do |root|
      root.merge!({})
      root.clear
      root.delete("missing")
      assert_raises(XitDB::UnsupportedValueError) { root["bad"] = true }
    end
    assert_nil @db.snapshot.revision
    assert_equal 0, @db.history.size
  end

  def test_deep_values_and_cyclic_upstream_graphs
    value = "leaf"
    1100.times { value = [value] }
    @db.transaction { |root| root["deep"] = value }
    materialized = @db.snapshot["deep"].to_ruby
    1100.times { materialized = materialized.first }
    assert_equal "leaf", materialized
    @db.core.transaction do |history_cursor|
      tx = history_cursor.transaction
      block = tx.append("\0".b * 144)
      header = tx.append([1, block].pack("Q>Q>"))
      cycle = XitDB::Core::Slot.new(tag: :array_list, value: header)
      tx.write_at(block, cycle.to_bytes)
      map = XitDB::Core::HashMap.new(tx.cursor(slot: XitDB::Core::Slot.new))
      map.put(Digest::SHA1.digest("cycle"), key: @db.core.bytes("cycle"), value: cycle)
      XitDB::Core::ArrayList.new(history_cursor).append(map.cursor.slot)
    end
    error = assert_raises(XitDB::CyclicValueError) { @db.snapshot.to_ruby }
    assert_equal ["cycle", 0], error.path
  end

  def test_open_rejects_invalid_history_roots_and_resolves_sha2_widths
    Dir.mktmpdir do |dir|
      %i[sha1 sha256 sha384 sha512].each do |algorithm|
        path = File.join(dir, "#{algorithm}.xit")
        XitDB.open(path, hash: algorithm) { |db| db.transaction { |root| root["n"] = 42 } }
        XitDB.open(path) { |db| assert_equal 42, db.snapshot["n"] }
      end
      path = File.join(dir, "bad-history.xit")
      XitDB::Core::Database.open(path) do |core|
        core.transaction { |cursor| XitDB::Core::ArrayList.new(cursor).append(XitDB::Core::Slot.new) }
      end
      original = File.binread(path)
      assert_raises(XitDB::ProfileMismatchError) { XitDB.open(path) }
      assert_equal original, File.binread(path)
    end
  end

  def test_inspect_is_bounded_without_reading_collection_entries
    @db.transaction { |root| root["x" * 10_000] = {"n" => 1} }
    assert_operator @db.snapshot["x" * 10_000].inspect.bytesize, :<, 300
  end

  def test_rejected_set_members_and_map_keys_report_the_assignment_path
    @db.transaction do |root|
      error = assert_raises(XitDB::UnsupportedValueError) { root["bad"] = Set[["a", "b"]] }
      assert_equal ["bad", ["a", "b"]], error.path
      assert_raises(XitDB::UnsupportedValueError) { root["bad"] = Set[true] }
      error = assert_raises(XitDB::UnsupportedValueError) { root[123] = "bad" }
      assert_equal [123], error.path
      assert_empty root
    end
    assert_nil @db.snapshot.revision
  end

  def test_transaction_rejects_a_new_invalid_root_before_yielding
    @db.core.transaction { |cursor| XitDB::Core::ArrayList.new(cursor).append(XitDB::Core::Slot.int(1)) }
    called = false
    assert_raises(XitDB::ProfileMismatchError) { @db.transaction { called = true } }
    refute called
  end

  def test_profile_adapters_edit_every_container_layout
    declarations = [XitDB.map, XitDB.map(counted: true), XitDB.sorted_map,
                    XitDB.set, XitDB.set(counted: true), XitDB.sorted_set,
                    XitDB.array, XitDB.linked_array]
    @db.transaction do |root|
      declarations.each_with_index do |declaration, index|
        key = index.to_s
        root[key] = declaration
        view = root[key]
        positional = %i[array_list linked_array_list].include?(declaration.kind)
        first, second = positional ? [0, 1] : ["a", "b"]
        root.context.mutate([key]) do |cursor|
          adapter = @db.profile.container(cursor.slot, context: root.context, path: [key])
          adapter.assign(first, XitDB::Core::Slot.int(1))
          adapter.assign(second, XitDB::Core::Slot.int(2))
          assert_equal 2, adapter.size
          refute_nil adapter.lookup(second)
          assert_equal [first, second], adapter.each_entry.map { |selector, _stored| selector }.sort
          adapter.delete(first)
          cursor.replace(adapter.slot)
        end
        expected = case declaration.kind
        when :array_list, :linked_array_list then [2]
        when :hash_set, :counted_hash_set, :sorted_set then Set["b"]
        else {"b" => 2}
        end
        assert_equal expected, view.to_ruby
      end
    end
  end

  def test_hash_callback_failure_keeps_its_identity_and_rolls_back_assignment
    failure = StopIteration.new("digest callback failed")
    hasher = XitDB::Core::Hasher.new(id: "test", size: 20) do |bytes|
      raise failure if bytes == "inner"

      Digest::SHA1.digest(bytes)
    end
    XitDB.memory(hash: hasher) do |db|
      db.transaction do |root|
        error = assert_raises(StopIteration) { root["outer"] = {"inner" => 1} }
        assert_same failure, error
        assert_empty root
      end
      assert_nil db.snapshot.revision
    end
  end

  def test_singleton_behavior_and_container_subclasses_are_rejected
    string = +"value"
    def string.special = 1
    extended = +"value"
    extended.extend(Module.new { def special = 1 })
    @db.transaction do |root|
      assert_raises(XitDB::UnsupportedValueError) { root[string] = 1 }
      [string, extended, Set.new.compare_by_identity, Class.new(Hash).new, Class.new(Array).new, Class.new(Set).new].each do |value|
        assert_raises(XitDB::UnsupportedValueError) { root["value"] = value }
        assert_empty root
      end
    end
  end

  private

  def return_from_transaction
    @db.transaction { |root| root["visits"] = 10; return :returned }
  end
end
