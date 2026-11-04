# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "open3"

class RubyDatabaseTest < Minitest::Test
  def setup
    require "xitdb/ruby"
    @db = XitDB::Ruby.memory
  end

  def teardown
    @db&.close
  end

  def test_ordered_native_keys_and_profile_isolation
    @db.transaction { |root| root[:name] = "symbol"; root["name"] = "string" }
    assert_equal [:name, "name"], @db.snapshot.keys
    @db.transaction { |root| root.delete(:name); root[:name] = "again" }
    assert_equal ["name", :name], @db.snapshot.keys
    Dir.mktmpdir do |directory|
      path = File.join(directory, "native.xit")
      XitDB::Ruby.open(path) { |db| db.transaction { |root| root[:name] = "native" } }
      assert_raises(XitDB::ProfileMismatchError) { XitDB.open(path) }
      assert_equal "rb01", File.binread(path, 4, 8)
      assert_equal 32, File.binread(path, 2, 6).unpack1("n")
      portable = File.join(directory, "portable.xit")
      XitDB.open(portable, &:close)
      before = File.binread(portable)
      assert_raises(XitDB::ProfileMismatchError) { XitDB::Ruby.open(portable) }
      assert_equal before, File.binread(portable)
    end
  end

  def test_scalar_keys_retain_original_representation_and_order
    keys = [nil, false, true, 1, 1.0, -0.0, :name, "name", 2**200, Float::INFINITY]
    @db.transaction do |root|
      keys.each_with_index { |key, index| root[key] = index }
      root[0.0] = "zero"
      root["name".encode("US-ASCII")] = "updated"
    end
    assert_equal keys, @db.snapshot.keys
    assert_equal(-Float::INFINITY, 1.0 / @db.snapshot.keys[5])
    assert_equal Encoding::UTF_8, @db.snapshot.keys[7].encoding
    assert_equal "zero", @db.snapshot[0.0]
    assert_equal 3, @db.snapshot[1]
    assert_equal 4, @db.snapshot[1.0]
    assert_equal keys.size, @db.snapshot.size
  end

  def test_native_collections_mutate_materialize_and_capture_history
    input = {name: [+"Ada", {active: true}], members: Set[1, "1", :one]}
    first = @db.transaction do |root|
      root[:data] = input
      root[:linked] = XitDB.linked_array
      root[:linked].push(1, 2, 3)
    end
    input[:name][0].replace("changed")
    @db.transaction do |root|
      root[:data][:name].insert(1, nil)
      root[:data][:name].delete_at(2)
      root[:data][:members].delete(1).add(1)
      root[:linked].insert(1, :middle)
      root[:linked].concat([4, 5])
      assert_equal [2, 3], root[:linked].pop(4).first(2)
    end
    assert_equal ["Ada", {active: true}], first[:data][:name].to_ruby
    assert_equal ["Ada", nil], @db.snapshot[:data][:name].to_ruby
    assert_equal ["1", :one, 1], @db.snapshot[:data][:members].to_a
    assert_equal [1, :middle], @db.snapshot[:linked].to_ruby
    materialized = @db.snapshot.to_ruby
    materialized[:data][:name][0].replace("independent")
    assert_equal "Ada", @db.snapshot[:data][:name][0]
    assert @db.snapshot[:data][:name][0].frozen?
    assert_equal 2, @db.history.size
    @db.revert(first.revision)
    assert_equal first.to_ruby, @db.snapshot.to_ruby
  end

  def test_rejected_input_is_atomic_and_does_not_execute_hooks
    calls = []
    singleton = []
    singleton.define_singleton_method(:each) { calls << :each }
    subclass = Class.new(Array) { define_method(:each) { raise "hook ran" } }.new
    default = Hash.new { calls << :default }
    identity = {}.compare_by_identity
    identity_set = Set.new.compare_by_identity
    cycle = []; cycle << cycle
    @db.transaction do |root|
      root[:kept] = 1
      [singleton, subclass, default, Hash.new(0), identity, identity_set, Set[[1]], Set[Time.now]].each do |value|
        assert_raises(XitDB::UnsupportedValueError) { root[:bad] = value }
        refute root.key?(:bad)
      end
      assert_raises(XitDB::CyclicValueError) { root[:bad] = cycle }
      [[], {}, Time.now, Float::NAN, Object.new].each do |key|
        assert_raises(XitDB::UnsupportedValueError) { root[key] = 2 }
      end
      assert_equal({kept: 1}, root.to_ruby)
    end
    assert_empty calls
  end

  def test_native_streams_use_typed_keys_and_binary_values
    escaped_reader = escaped_writer = nil
    @db.transaction do |root|
      root[:text] = "ordinary"
      assert_raises(XitDB::InvalidValueError) { root.open_bytes(:text) { flunk } }
      [nil, false, true, 1, 1.0, :blob, "blob"].each do |key|
        root.write_bytes(key) do |writer|
          escaped_writer = writer
          assert_raises(XitDB::ConcurrentModificationError) { root[key] = "bad" }
          writer.write("\x00\xff".b)
        end
        root.open_bytes(key) { |reader| escaped_reader = reader; assert_equal "\x00\xff".b, reader.read }
      end
      [[], XitDB.linked_array].each do |declaration|
        root[:array] = declaration
        items = root[:array]
        items.write_bytes(1) do |writer|
          assert_raises(XitDB::ConcurrentModificationError) { items[2] = "bad" }
          writer.write("bytes")
        end
        assert_equal [nil, "bytes".b], items.to_ruby
        items.open_bytes(-1) do |reader|
          assert_raises(XitDB::ConcurrentModificationError) { items.insert(0, 1) }
          assert_equal "bytes", reader.read
        end
        assert_equal "bytes", items[1, 1].open_bytes(0, &:read)
      end
      root.write_bytes("equal") do |writer|
        assert_raises(XitDB::ConcurrentModificationError) { root["equal".b] = 1 }
        root[:equal] = 2
        writer.write("binary")
      end
    end
    binary = @db.snapshot[:blob]
    assert_equal Encoding::BINARY, binary.encoding
    assert binary.frozen?
    copy = @db.snapshot.to_ruby
    copy[:blob].replace("changed")
    assert_equal "\x00\xff".b, @db.snapshot[:blob]
    assert_raises(XitDB::ExpiredViewError) { escaped_reader.read }
    assert_raises(XitDB::ExpiredViewError) { escaped_writer.write("late") }
  end

  def test_persistence_across_processes_and_unknown_profiles
    Dir.mktmpdir do |directory|
      path = File.join(directory, "native.xit")
      script = 'require "xitdb/ruby"; XitDB::Ruby.open(ARGV[0]) { |db| db.transaction { |r| r[:name] = "Ada"; r[2**200] = [true, Rational(2, 3)]; r["name"] = Set[1, :one] } }'
      output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, path)
      assert status.success?, output
      XitDB::Ruby.open(path, readonly: true) do |db|
        assert_equal [:name, 2**200, "name"], db.snapshot.keys
        assert_equal [true, Rational(2, 3)], db.snapshot[2**200].to_ruby
        assert_equal Set[1, :one], db.snapshot["name"].to_ruby
        assert_raises(XitDB::ReadOnlyError) { db.transaction {} }
      end
      unknown = File.join(directory, "unknown.xit")
      XitDB::Core::Database.open(unknown, hash_id: "zzzz", hash_size: 32, &:close)
      assert_raises(XitDB::ProfileMismatchError) { XitDB::Ruby.open(unknown) }
      zero = File.join(directory, "zero.xit")
      File.binwrite(zero, "")
      assert_raises(XitDB::CorruptionError) { XitDB::Ruby.open(zero) }
      assert_equal "", File.binread(zero)
    end
  end

  def test_insertion_overflow_preserves_updates_and_clear_resets_empty_indexes
    [false, true].each do |set|
      @db.transaction do |root|
        root[:items] = set ? Set[:first] : {first: 1}
        items = root[:items]
        context = items.context
        context.mutate(items.path) do |cursor|
          envelope = XitDB::Core::ArrayList.new(cursor)
          envelope.put(1, XitDB::Core::Slot.uint((1 << 64) - 1))
        end
        before = root.to_ruby
        assert_raises(RangeError) { set ? items.add(:second) : items[:second] = 2 }
        assert_equal before, root.to_ruby
        items[:first] = 3 unless set
        items.delete(:first)
        assert_empty items
        assert_raises(RangeError) { set ? items.add(:second) : items[:second] = 2 }
        items.clear
        set ? items.add(:second) : items[:second] = 2
        assert_equal [:second], set ? items.to_a : items.keys
        assert_equal 1, physical_envelope(items).get(1).value
      end
    end
  end

  def test_exact_envelopes_and_index_records
    @db.transaction do |root|
      root[:array] = [1]
      root[:linked] = XitDB.linked_array
      root[:set] = Set[:member]
    end
    snapshot = @db.snapshot
    envelope = physical_envelope(snapshot)
    assert_equal 4, envelope.size
    assert_equal 0x52420103, envelope.get(0).value
    assert_equal 3, envelope.get(1).value
    assert_equal :counted_hash_map, envelope.get(2).tag
    assert_equal :sorted_map, envelope.get(3).tag
    [[:array, 0x52420101, :array_list], [:linked, 0x52420102, :linked_array_list]].each do |key, marker, tag|
      item = physical_envelope(snapshot[key])
      assert_equal 2, item.size
      assert_equal marker, item.get(0).value
      assert_equal tag, item.get(1).tag
    end
    set = physical_envelope(snapshot[:set])
    assert_equal 0x52420104, set.get(0).value
    lookup = XitDB::Core::HashMap.new(snapshot.context.cursor(set.get(2)), counted: true)
    digest, key, record_slot = lookup.each_entry.first
    assert_equal Digest::SHA256.digest("\x06\x00\x06member".b), digest
    assert_equal "\x06\x00\x06member".b, @db.core.read_bytes(key).bytes
    record = XitDB::Core::ArrayList.new(snapshot.context.cursor(record_slot))
    assert_equal 3, record.size
    assert_equal XitDB::Core::Slot.null, record.get(1)
    assert_equal 0, record.get(2).value
    order = XitDB::Core::SortedMap.new(snapshot.context.cursor(set.get(3)))
    id, hash_slot = order.each.first
    assert_equal "\0".b * 8, id
    assert_equal digest, @db.core.read_bytes(hash_slot).bytes
  end

  def test_malformed_envelopes_and_conflicting_indexes_are_rejected
    @db.transaction do |root|
      root[:array] = []
      root[:map] = {key: 1}
      [[0, XitDB::Core::Slot.uint(0)], [1, XitDB::Core::Slot.int(1)]].each do |index, value|
        context = root.context
        assert_raises(XitDB::InvalidValueError) do
          context.mutate([:array]) do |cursor|
            XitDB::Core::ArrayList.new(cursor).put(index, value)
            @db.profile.container(cursor.slot, context: context, path: [:array])
          end
        end
        assert_empty root[:array]
      end
      context = root.context
      assert_raises(XitDB::InvalidValueError) do
        context.mutate([:map]) do |cursor|
          envelope = XitDB::Core::ArrayList.new(cursor)
          order_cursor = context.cursor(envelope.get(3))
          XitDB::Core::SortedMap.new(order_cursor).put("\0".b * 8, value: @db.core.bytes("x" * 32))
          envelope.put(3, order_cursor.slot)
          @db.profile.container(cursor.slot, context: context, path: [:map]).lookup(:key)
        end
      end
      assert_equal({key: 1}, root[:map].to_ruby)
    end
  end

  def test_handle_configuration_is_owned_and_rejected_before_file_creation
    codecs = []
    other = XitDB::Ruby.memory(codecs: codecs)
    codecs << Object.new
    assert_empty other.profile.codecs
    refute_same other.profile, @db.profile
    Dir.mktmpdir do |directory|
      path = File.join(directory, "rejected.xit")
      assert_raises(XitDB::CodecConfigurationError) { XitDB::Ruby.open(path, codecs: codecs) }
      refute File.exist?(path)
    end
  ensure
    other&.close
  end

  def test_nonempty_codec_configuration_cannot_override_emptiness
    calls = []
    codecs = [Object.new]
    codecs.define_singleton_method(:empty?) { calls << :empty; true }
    assert_raises(XitDB::CodecConfigurationError) { XitDB::Ruby.memory(codecs: codecs, &:close) }
    assert_empty calls
  end

  def test_invalid_codec_configuration_rejects_without_input_hooks_or_file_creation
    configurations = [Class.new(Array).new([Object.new]), [Object.new], Object.new, BasicObject.new]
    Dir.mktmpdir do |directory|
      configurations.each_with_index do |codecs, index|
        calls = []
        if Object === codecs
          %i[instance_of? class empty? dup initialize_dup].each do |method|
            codecs.define_singleton_method(method) { |*| calls << method; raise "configuration hook ran" }
          end
        end
        path = File.join(directory, "invalid-#{index}.xit")
        assert_raises(XitDB::CodecConfigurationError) { XitDB::Ruby.memory(codecs: codecs, &:close) }
        assert_raises(XitDB::CodecConfigurationError) { XitDB::Ruby.open(path, codecs: codecs, &:close) }
        assert_empty calls
        refute File.exist?(path)
      end
    end
  end

  def test_empty_codec_configuration_is_owned_without_copy_or_reflection_hooks
    calls = []
    codecs = []
    %i[instance_of? class empty? dup initialize_dup].each do |method|
      codecs.define_singleton_method(method) { |*| calls << method; raise "configuration hook ran" }
    end
    first = XitDB::Ruby.memory(codecs: codecs)
    second = XitDB::Ruby.memory(codecs: codecs)
    assert_empty first.profile.codecs
    assert_empty second.profile.codecs
    assert first.profile.codecs.frozen?
    assert second.profile.codecs.frozen?
    refute_same codecs, first.profile.codecs
    refute_same codecs, second.profile.codecs
    refute_same first.profile.codecs, second.profile.codecs
    Dir.mktmpdir do |directory|
      path = File.join(directory, "empty.xit")
      accepted = nil
      assert_equal :done, XitDB::Ruby.open(path, codecs: codecs) { |db| accepted = db; :done }
      assert accepted.closed?
      assert File.exist?(path)
    end
    codecs << Object.new
    assert_empty first.profile.codecs
    assert_empty second.profile.codecs
    assert_empty calls
  ensure
    first&.close
    second&.close
  end

  def test_clear_is_atomic_and_invalidates_children_and_iterators
    @db.transaction do |root|
      root[:items] = {first: [], second: 2}
      items = root[:items]
      child = items[:first]
      iterator = items.each
      iterator.next
      transaction = root.context.transaction
      original = transaction.method(:append)
      fail_append = true
      transaction.define_singleton_method(:append) do |bytes|
        result = original.call(bytes)
        raise IOError, "injected clear failure" if fail_append
        result
      end
      assert_raises(IOError) { items.clear }
      assert_equal [:first, :second], items.keys
      assert_empty child
      fail_append = false
      items.clear
      assert_raises(XitDB::ExpiredViewError) { child.size }
      assert_raises(XitDB::ConcurrentModificationError) { iterator.next }
      assert_equal 0, physical_envelope(items).get(1).value
      root.write_bytes(:stream) do |writer|
        assert_raises(XitDB::ConcurrentModificationError) { root.clear }
        writer.write("kept")
      end
    end
  end

  def test_equal_key_aliases_share_expiry_and_stream_identity
    @db.transaction do |root|
      root[-0.0] = []
      child = root[0.0]
      root[0.0] = []
      assert_raises(XitDB::ExpiredViewError) { child.size }
      root[1] = []
      integer_child = root[1]
      root[1.0] = []
      assert_empty integer_child
      root.write_bytes(-0.0) do |writer|
        assert_raises(XitDB::ConcurrentModificationError) { root[0.0] = "bad" }
        root[0] = "integer"
        writer.write("float")
      end
      assert_equal "float", root.open_bytes(0.0, &:read)
      assert_equal "integer", root[0]
      root["ascii"] = []
      text_child = root["ascii".b]
      root["ascii".encode("US-ASCII")] = 1
      assert_raises(XitDB::ExpiredViewError) { text_child.size }
    end
  end

  def test_native_streams_enforce_threads_readonly_and_failed_assignment_ownership
    escaped = nil
    @db.transaction do |root|
      root.write_bytes(:blob) { |writer| writer.write("before") }
      root.open_bytes(:blob) do |reader|
        assert_instance_of XitDB::TransactionStateError, Thread.new { reader.read rescue $! }.value
      end
      assert_raises(RuntimeError) do
        root.write_bytes(:blob) do |writer|
          escaped = writer
          assert_instance_of XitDB::TransactionStateError, Thread.new { writer.write("bad") rescue $! }.value
          root[:sibling] = true
          writer.write("discarded")
          raise "abort stream"
        end
      end
      assert_equal "before", root[:blob]
      assert_equal true, root[:sibling]
    end
    assert_raises(XitDB::ExpiredViewError) { escaped.pos }
    assert_raises(XitDB::ReadOnlyError) { @db.snapshot.write_bytes(:blob) { flunk } }
    foreign = XitDB::Ruby.memory
    assert_raises(XitDB::ForeignValueError) { foreign.transaction { |root| root[:copied] = @db.snapshot } }
  ensure
    foreign&.close
  end

  def test_native_size_and_single_lookup_do_not_materialize_unrelated_values
    @db.transaction do |root|
      root[:items] = (0...100).to_h { |index| [index, [index, "value"]] }
      root[:untouched] = XitDB.bytes("\x02\x01".b, format_tag: "rb")
    end
    snapshot = @db.snapshot
    core = @db.core
    original = core.method(:read_bytes)
    decoded = []
    core.define_singleton_method(:read_bytes) do |stored, **options|
      decoded << stored
      original.call(stored, **options)
    end
    items = snapshot[:items]
    decoded.clear
    assert_equal 100, items.size
    size_reads = decoded.size
    assert_operator size_reads, :<, 10
    decoded.clear
    assert_equal [42, "value"], items[42].to_ruby
    assert_operator decoded.size, :<, 100
    assert_raises(XitDB::UnsupportedEncodingError) { snapshot[:untouched] }
  end

  def test_nested_containers_capture_shared_inputs_and_reject_cycles_atomically
    shared = ["value"]
    @db.transaction do |root|
      root[:pair] = [shared, shared]
      root[:pair][0] << 1
      assert_equal [["value", 1], ["value"]], root[:pair].to_ruby
      before = root.to_ruby
      bad = {ok: [1], bad: {deep: Object.new}}
      error = assert_raises(XitDB::UnsupportedValueError) { root.merge!(bad) }
      assert_equal [:bad, :deep], error.path
      assert_equal before, root.to_ruby
      nested = 1
      100.times { nested = [nested] }
      root[:deep] = nested
      materialized = root[:deep].to_ruby
      100.times { materialized = materialized[0] }
      assert_equal 1, materialized
    end
  end

  def test_failed_lookup_index_write_restores_order_and_identifier
    @db.transaction do |root|
      root[:items] = {first: 1}
      items = root[:items]
      transaction = root.context.transaction
      original = transaction.method(:append)
      fail_record = true
      transaction.define_singleton_method(:append) do |bytes|
        result = original.call(bytes)
        raise IOError, "injected lookup record failure" if fail_record && bytes.bytesize == 50
        result
      end
      bound = transaction.length
      assert_raises(IOError) { items[:second] = 2 }
      assert_equal bound, transaction.length
      assert_equal({first: 1}, items.to_ruby)
      assert_equal 1, physical_envelope(items).get(1).value
      fail_record = false
      items[:second] = 2
      assert_equal [:first, :second], items.keys
      assert_equal 2, physical_envelope(items).get(1).value
    end
  end

  def test_failed_lookup_removal_restores_both_indexes
    @db.transaction do |root|
      root[:items] = {first: 1, second: 2}
      items = root[:items]
      transaction = root.context.transaction
      original = transaction.method(:write_at)
      fail_count = true
      transaction.define_singleton_method(:write_at) do |offset, bytes|
        result = original.call(offset, bytes)
        raise IOError, "injected lookup count failure" if fail_count && bytes.bytesize == 8
        result
      end
      bound = transaction.length
      assert_raises(IOError) { items.delete(:first) }
      assert_equal bound, transaction.length
      assert_equal({first: 1, second: 2}, items.to_ruby)
      assert_equal 2, items.size
      fail_count = false
      assert_equal 1, items.delete(:first)
      assert_equal [:second], items.keys
    end
  end

  def test_empty_and_non_ascii_key_equality_preserves_original_encoding
    @db.transaction do |root|
      root["".encode("UTF-16LE")] = 1
      root[""] = 2
      root["\u00e9"] = "text"
      root["\xc3\xa9".b] = "binary"
    end
    assert_equal 3, @db.snapshot.size
    assert_equal Encoding::UTF_16LE, @db.snapshot.keys.first.encoding
    assert_equal 2, @db.snapshot["".b]
    assert_equal "text", @db.snapshot["\u00e9"]
    assert_equal "binary", @db.snapshot["\xc3\xa9".b]
  end

  def test_linked_slices_and_concatenation_preserve_native_envelopes
    @db.transaction do |root|
      root[:items] = XitDB.linked_array
      root[:items].push(1, 2, 3, 4)
      left, right = root[:items].split(2)
      root[:copy] = right
      root[:items].concat(left)
      assert_equal [1, 2, 3, 4, 1, 2], root[:items].to_ruby
      assert_equal [3, 4], root[:copy].to_ruby
      assert_equal :linked_array, root[:copy].kind
      root[:items].clear
      assert_empty root[:items]
      assert_equal [3, 4], root[:copy].to_ruby
    end
  end

  def test_unregistered_scalar_subclasses_reject_before_encoding_hooks
    calls = []
    values = [
      [Class.new(String).new("value"), :encoding],
      [Class.new(Time).at(0), :to_r],
      [Class.new(Date).jd(0), :jd],
      [Class.new(DateTime).jd(0), :ajd],
      [Class.new(XitDB::Core::ByteValue).new("bytes"), :bytes],
      [Class.new(XitDB::Ruby::EncodedValue).new(codec_id: "example", bytes: "payload"), :bytes]
    ]
    values.each do |value, method|
      value.class.define_method(method) { calls << method; raise "subclass hook ran" }
    end
    @db.transaction do |root|
      root[:kept] = 1
      values.each do |value, _method|
        assert_raises(XitDB::UnsupportedValueError) { XitDB::Ruby::Scalars.encode(value, core: @db.core) }
        assert_raises(XitDB::UnsupportedValueError) { root[:bad] = value }
        refute root.key?(:bad)
        assert_equal({kept: 1}, root.to_ruby)
      end
      string = values.first.first
      assert_raises(XitDB::UnsupportedValueError) { XitDB::Ruby::KeyEncoding.dump(string) }
      assert_raises(XitDB::UnsupportedValueError) { root[string] = 2 }
      assert_equal({kept: 1}, root.to_ruby)
    end
    assert_empty calls
  end

  def test_collection_declaration_subclasses_reject_without_running_hooks
    calls = []
    klass = Class.new(XitDB::CollectionDeclaration)
    declaration = klass.new(:array_list)
    klass.define_method(:kind) { calls << :kind; :array_list }
    klass.define_singleton_method(:==) { |_other| calls << :comparison; raise "class comparison hook ran" }
    @db.transaction do |root|
      root[:kept] = 1
      assert_raises(XitDB::UnsupportedValueError) { root[:bad] = declaration }
      assert_equal({kept: 1}, root.to_ruby)
    end
    assert_empty calls
  end

  def test_public_subclass_rejection_bypasses_type_hooks_and_accepts_real_views
    calls = []
    values = [Class.new(String).new("value"), Class.new(Array).new,
              Class.new(Hash).new, Class.new(Set).new]
    values.each do |value|
      value.class.define_method(:is_a?) { |_type| calls << :is_a; raise "type hook ran" }
    end
    snapshot = @db.transaction { |root| root[:source] = ["original"] }
    @db.transaction do |root|
      values.each do |value|
        assert_raises(XitDB::UnsupportedValueError) { root[:bad] = value }
        refute root.key?(:bad)
      end
      root[:copy] = snapshot[:source]
      root[:source] << "changed"
      assert_equal ["original"], root[:copy].to_ruby
      assert_equal ["original", "changed"], root[:source].to_ruby
    end
    assert_empty calls
  end

  def test_bulk_subclass_predicates_cannot_mutate_the_transaction
    @db.transaction do |root|
      root[:kept] = "value"
      root[:array] = [[1], [2]]
      calls = []
      hash_class = Class.new(Hash)
      hash_class.define_method(:instance_of?) { |*| calls << :hash; root.clear; raise "hash hook ran" }
      array_class = Class.new(Array)
      array_class.define_method(:is_a?) { |*| calls << :array; root.clear; raise "array hook ran" }
      array = root[:array]
      child = array[0]
      iterator = array.each
      assert_equal [1], iterator.next.to_ruby
      before = root.to_ruby
      assert_raises(TypeError) { root.merge!(hash_class.new) }
      assert_raises(XitDB::UnsupportedValueError) { array.concat(array_class.new) }
      assert_empty calls
      assert_equal before, root.to_ruby
      assert_equal [2], iterator.next.to_ruby
      child << 3
      root[:rescued] = "yes"
    end
    assert_equal({kept: "value", array: [[1, 3], [2]], rescued: "yes"}, @db.snapshot.to_ruby)
  end

  def test_bulk_merge_stream_targets_reject_key_type_hooks
    @db.transaction do |root|
      root[:kept] = "value"
      calls = []
      klass = Class.new(String)
      klass.define_method(:is_a?) { |*| calls << :key; root.clear; raise "key hook ran" }
      input = {klass.new("key") => 1}
      root.write_bytes(:stream) do |writer|
        assert_raises(XitDB::UnsupportedValueError) { root.merge!(input) }
        assert_empty calls
        assert_equal({kept: "value"}, root.to_ruby)
        writer.write("data")
      end
      assert_equal "data", root.open_bytes(:stream, &:read)
    end
  end

  def test_coercion_reentrant_writes_reject_without_expiring_prior_views
    [[], XitDB.linked_array].each do |declaration|
      @db.transaction do |root|
        root[:kept] = "value"
        root[:array] = declaration
        array = root[:array].push([1], [2])
        child = array[0]
        iterator = array.each
        assert_equal [1], iterator.next.to_ruby
        before = root.to_ruby
        bound = root.context.read_bound
        [-> { root.clear; raise "callback failed" }, -> { root[:sibling] = "nested write"; [3] }].each do |callback|
          coercer = Object.new
          coercer.define_singleton_method(:to_ary, &callback)
          assert_raises(XitDB::TransactionStateError) { array.concat(coercer) }
          assert_equal bound, root.context.read_bound
          assert_equal before, root.to_ruby
          assert_equal [1], child.to_ruby
        end
        assert_equal [2], iterator.next.to_ruby
        child << 3
        array.concat([4])
        assert_equal [[1, 3], [2], 4], array.to_ruby
      end
    end
  end

  def test_coercion_reads_and_handled_cross_context_rejection_can_complete
    @db.transaction do |root|
      root[:array] = [1]
      root[:detached] = {value: 2}
      detached = root.delete(:detached)
      refute_same root.context, detached.context
      readonly = root[:array][0, 1]
      snapshot = @db.snapshot
      coercer = Object.new
      test = self
      coercer.define_singleton_method(:to_ary) do
        test.assert_equal [1], root[:array].to_ruby
        test.assert_equal 2, detached[:value]
        test.assert_raises(XitDB::ReadOnlyError) { readonly.clear }
        test.assert_raises(XitDB::ReadOnlyError) { snapshot[:bad] = 1 }
        test.assert_raises(XitDB::TransactionStateError) { detached[:value] = 3 }
        test.assert_raises(XitDB::TransactionStateError) { root[:sibling] = 4 }
        [2]
      end
      root[:array].concat(coercer)
      assert_equal [1, 2], root[:array].to_ruby
      assert_equal 2, detached[:value]
      detached[:value] = 5
      root[:copy] = detached
      assert_equal({value: 5}, root[:copy].to_ruby)
      root.write_bytes(:stream) do |writer|
        root[:sibling] = 6
        writer.write("stream")
      end
      assert_equal 6, root[:sibling]
    end
  end

  def test_coercion_nonlocal_exit_restores_context_and_allows_later_mutation
    @db.transaction do |root|
      root[:items] = [1]
      items = root[:items]
      before = root.context.read_bound
      coercer = Object.new
      coercer.define_singleton_method(:to_ary) { throw :stop, :stopped }
      assert_equal :stopped, catch(:stop) { items.concat([2], coercer) }
      assert_equal before, root.context.read_bound
      assert_equal [1], items.to_ruby
      items.concat([3])
      assert_equal [1, 3], items.to_ruby
    end
  end

  private

  def physical_envelope(view)
    XitDB::Core::ArrayList.new(view.context.cursor(view.slot))
  end
end
