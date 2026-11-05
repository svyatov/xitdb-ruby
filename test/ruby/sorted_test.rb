# frozen_string_literal: true

require_relative "test_helper"
require "xitdb/ruby"
require "tmpdir"

class RubySortedTest < RubyProfileTest
  def test_ordered_bytes_match_exact_numeric_and_time_order
    numbers = [-(2**200), -1, 0, 1, 2**200]
    assert_equal(numbers, numbers.shuffle.sort_by { |n| ordered(n, :integer) })
    times = [Rational(-1, 3), 0, Rational(1, 10**12), Rational(1, 3)]
    assert_equal(times, times.shuffle.sort_by { |t| ordered(Time.at(t), :time) })
  end

  def test_wire_vectors_and_prefix_order
    { -256 => "00fffffffffffffffdfeff", -1 => "00fffffffffffffffefe",
      0 => "01", 1 => "02000000000000000101", 256 => "0200000000000000020100" }.each do |number, hex|
      assert_equal hex, ordered(number, :integer).unpack1("H*")
    end
    { -Float::INFINITY => "000fffffffffffff", -1.0 => "400fffffffffffff",
      -0.0 => "8000000000000000", 1.0 => "bff0000000000000",
      Float::INFINITY => "fff0000000000000" }.each do |number, hex|
      assert_equal hex, ordered(number, :float).unpack1("H*")
    end
    { Rational(-1, 2) => "00fffffffffffffffffe00000000000000010200",
      0 => "01", Rational(1, 2) => "02000000000000000001fffffffffffffffefdff",
      1 => "0200000000000000010100" }.each do |number, hex|
      assert_equal hex, ordered(Time.at(number), :time).unpack1("H*")
    end
    strings = ["", "a", "a\0", "aa", "b", "é"]
    assert_equal(strings, strings.reverse.sort_by { |s| ordered(s, :string) })
    assert_equal "c3a9", ordered("é".encode("ISO-8859-1"), :string).unpack1("H*")
    assert_equal Encoding::BINARY, ordered("é", :string).encoding
  end

  def test_exact_time_order_with_large_denominators_and_long_continued_fractions
    a = 1
    b = 1
    2500.times { a, b = b, a + b }
    values = [-Rational(b, a), -Rational(1, 10**100), 0, Rational(1, 10**100), Rational(a, b), Rational(b, a)]
    assert_equal(values, values.reverse.sort_by { |r| ordered(Time.at(r), :time) })
    assert_operator ordered(Time.at(Rational(1, 10**100)), :time).bytesize, :<, 100
  end

  def test_ordered_key_validation_precedes_input_hooks
    { string: "a", integer: 1, float: 1.0, time: Time.at(0) }.each do |kind, value|
      assert_raises(XitDB::UnsupportedValueError) { ordered(nil, kind) }
      assert_raises(XitDB::UnsupportedValueError) { ordered(value, :unknown) }
    end
    assert_raises(XitDB::UnsupportedValueError) { ordered(Float::NAN, :float) }
    assert_raises(XitDB::UnsupportedEncodingError) { ordered("\xff".b, :string) }
    assert_raises(XitDB::UnsupportedEncodingError) { ordered("\xff".dup.force_encoding("UTF-8"), :string) }
    calls = []
    klass = Class.new(String) do
      define_method(:is_a?) do |*|
        calls << :type
        true
      end
      define_method(:encode) do |*|
        calls << :encode
        "a"
      end
    end
    assert_raises(XitDB::UnsupportedValueError) { ordered(klass.new("a"), :string) }
    assert_empty calls
    singleton_inputs.each { |input| assert_raises(XitDB::UnsupportedValueError) { ordered(input, :string) } }
  end

  def test_typed_declarations_and_portable_isolation
    XitDB::Ruby.memory do |db|
      db.transaction do |root|
        %i[sorted_map sorted_set].each do |type|
          error = assert_raises(XitDB::UnsupportedValueError) { root[:bad] = XitDB.public_send(type) }
          assert_match(/key:/, error.message)
          %i[string integer float time].each do |kind|
            root[:value] = XitDB.public_send(type, key: kind)
            assert_empty root[:value]
          end
        end
        refute root.key?(:bad)
      end
    end
    XitDB.memory do |db|
      db.transaction do |root|
        %i[sorted_map sorted_set].each do |type|
          assert_raises(XitDB::UnsupportedValueError) { root["bad"] = XitDB.public_send(type, key: :string) }
          root["value"] = XitDB.public_send(type)
          assert_empty root["value"]
        end
      end
    end
    [:object, false, 1, "integer"].each do |kind|
      assert_raises(ArgumentError) { XitDB.sorted_map(key: kind) }
    end
    calls = []
    kind = Object.new
    kind.define_singleton_method(:nil?) do
      calls << :nil
      true
    end
    assert_raises(ArgumentError) { XitDB.sorted_map(key: kind) }
    assert_empty calls
  end

  def test_typed_maps_and_sets_order_rank_and_snapshot_pages
    { integer: [-(2**200), -1, 0, 1, 2**200], float: [-Float::INFINITY, -1.0, 0.0, 1.0, Float::INFINITY],
      string: ["", "a", "a\0", "aa", "é"],
      time: [-1, 0, Rational(1, 10**12), Rational(1, 3), 1].map { |r| Time.at(r) } }.each do |kind, keys|
      XitDB::Ruby.memory do |db|
        before = db.transaction do |root|
          root[:map] = XitDB.sorted_map(key: kind)
          root[:set] = XitDB.sorted_set(key: kind)
          keys.reverse_each do |key|
            root[:map][key] = [key]
            root[:set].add(key)
          end
          assert_equal keys, root[:map].keys
          assert_equal keys, root[:set].to_a
          keys.each_with_index do |key, index|
            assert_equal index, root[:map].rank(key)
            assert_equal index, root[:set].rank(key)
            assert_equal key, root[:map][key][0]
          end
          assert_equal(keys.drop(2), root[:map].from(keys[2]).map { |key, _| key })
          assert_equal keys.last(2), root[:set].from_index(-2).to_a
        end
        db.transaction do |root|
          child = root[:map][keys[2]]
          iterator = root[:map].each
          iterator.next
          root[:map][keys[2]] = [:changed]
          assert_raises(XitDB::ExpiredViewError) { child.size }
          assert_equal([keys[1], [keys[1]]], iterator.next.then { |key, view| [key, view.to_ruby] })
          child = root[:map][keys[2]]
          removed = root[:map].delete(keys[2])
          assert_raises(XitDB::ExpiredViewError) { child.size }
          assert_equal [:changed], removed.to_ruby
          assert_raises(XitDB::ConcurrentModificationError) { iterator.next }
          root[:set].delete(keys[2])
          assert_equal 4, root[:map].size
          assert_equal 4, root[:set].size
        end
        assert_equal(keys[1, 2], before[:map].page(offset: 1, limit: 2).map { |key, _| key })
        assert_equal keys[1, 2], before[:set].page(offset: 1, limit: 2).to_a
        assert_equal keys, before[:map].keys
      end
    end
  end

  def test_comparison_aliases_retain_original_keys_and_invalidate_descendants
    { string: ["é".encode("ISO-8859-1"), "é"],
      time: [Time.at(Rational(1, 3)).getlocal(3600), Time.at(Rational(1, 3)).getlocal(-7200)],
      float: [-0.0, 0.0] }.each do |kind, (original, other)|
      XitDB::Ruby.memory do |db|
        db.transaction do |root|
          root[:map] = XitDB.sorted_map(key: kind)
          root[:set] = XitDB.sorted_set(key: kind)
          map = root[:map]
          set = root[:set]
          map[original] = { child: [1] }
          set.add(original).add(other)
          child = map[other][:child]
          child.push(2)
          assert_equal [1, 2], map[original][:child].to_ruby
          map[other] = { child: [3] }
          assert_raises(XitDB::ExpiredViewError) { child.size }
          assert_equal 1, map.size
          assert_equal 1, set.size
          [map.keys.first, set.to_a.first].each do |stored|
            case kind
            when :string then assert_equal Encoding::ISO_8859_1, stored.encoding
            when :time then assert_equal 3600, stored.utc_offset
            when :float then assert_equal(-Float::INFINITY, 1.0 / stored)
            end
          end
          child = map[other][:child]
          map.delete(original)
          assert_raises(XitDB::ExpiredViewError) { child.size }
        end
      end
    end
  end

  def test_streams_use_sorted_identity_and_allow_unrelated_writes
    { string: ["é".encode("ISO-8859-1"), "é", "z"],
      time: [Time.at(Rational(1, 3)).getlocal(3600), Time.at(Rational(1, 3)).utc,
             Time.at(2)] }.each do |kind, (key, other, adjacent)|
      XitDB::Ruby.memory do |db|
        db.transaction do |root|
          root[:map] = XitDB.sorted_map(key: kind)
          map = root[:map]
          map.write_bytes(key) { |writer| writer.write("old") }
          map.open_bytes(other) do |reader|
            assert_equal "old", reader.read
            assert_raises(XitDB::ConcurrentModificationError) { map[other] = 9 }
            assert_raises(XitDB::ConcurrentModificationError) { map.delete(other) }
            assert_raises(XitDB::ConcurrentModificationError) { map.merge!(other => 9) }
            assert_raises(XitDB::ConcurrentModificationError) { map.write_bytes(other) { |writer| writer.write("bad") } }
            map[adjacent] = 8
          end
          map.write_bytes(other) do |writer|
            writer.write("new")
            root[:sibling] = 7
            assert_raises(XitDB::ConcurrentModificationError) { map[key] = 9 }
          end
          assert_equal "new".b, map[key]
          assert_equal 8, map[adjacent]
          assert_equal 7, root[:sibling]
          assert_raises(XitDB::UnsupportedValueError) { root[Time.at(0)] = 1 }
        end
      end
    end
  end

  def test_descendant_streams_block_replacement_through_sorted_aliases
    { string: ["é".encode("ISO-8859-1"), "é"],
      time: [Time.at(Rational(-1, 3)).getlocal(3600), Time.at(Rational(-1, 3)).utc] }.each do |kind, (key, other)|
      XitDB::Ruby.memory do |db|
        db.transaction do |root|
          root[:map] = XitDB.sorted_map(key: kind)
          map = root[:map]
          map[key] = { data: XitDB.bytes("kept") }
          map[other].open_bytes(:data) do |reader|
            assert_raises(XitDB::ConcurrentModificationError) { map[key] = 1 }
            assert_raises(XitDB::ConcurrentModificationError) { map.delete(key) }
            assert_raises(XitDB::ConcurrentModificationError) { map.merge!(key => 1) }
            assert_raises(XitDB::ConcurrentModificationError) { map.clear }
            assert_equal "kept", reader.read
          end
          assert_equal "kept".b, map[key][:data]
        end
      end
    end
  end

  def test_public_sorted_keys_and_merge_reject_hooks_before_any_mutation
    calls = []
    bad_key = Class.new(String) do
      define_method(:is_a?) do |*|
        calls << :type
        raise "key hook ran"
      end
      define_method(:encode) do |*|
        calls << :encode
        raise "key hook ran"
      end
    end.new("bad")
    bad_hash = Class.new(Hash) do
      define_method(:instance_of?) do |*|
        calls << :type
        true
      end
    end.new
    singleton = {}
    singleton.define_singleton_method(:each_pair) { |*| calls << :each }
    XitDB::Ruby.memory do |db|
      db.transaction do |root|
        root[:map] = XitDB.sorted_map(key: :string)
        root[:set] = XitDB.sorted_set(key: :string)
        map = root[:map]
        set = root[:set]
        map["kept"] = XitDB.bytes("value")
        map.open_bytes("kept") do |reader|
          assert_raises(TypeError) { map.merge!(bad_hash) }
          assert_raises(XitDB::UnsupportedValueError) { map.merge!(singleton) }
          assert_raises(XitDB::UnsupportedValueError) { map.merge!(bad_key => 1) }
          assert_raises(XitDB::UnsupportedValueError) { map[bad_key] = 1 }
          assert_raises(XitDB::UnsupportedValueError) { map.write_bytes(bad_key) { |writer| writer.write("bad") } }
          assert_raises(XitDB::UnsupportedValueError) { map.rank(bad_key) }
          assert_raises(XitDB::UnsupportedValueError) { map.from(bad_key).to_a }
          assert_raises(XitDB::UnsupportedValueError) { set.add(bad_key) }
          assert_equal "value", reader.read
        end
        assert_empty calls
        assert_equal ["kept"], map.keys
        assert_empty set
      end
    end
  end

  def test_typed_merge_validates_keys_and_rolls_back_all_entries
    XitDB::Ruby.memory do |db|
      db.transaction do |root|
        root[:map] = XitDB.sorted_map(key: :time)
        map = root[:map]
        first = Time.at(1)
        second = Time.at(2)
        map[first] = [1]
        child = map[first]
        iterator = map.each
        iterator.next
        length = root.context.transaction.length
        assert_raises(XitDB::UnsupportedValueError) { map.merge!(second => [2], "bad" => [3]) }
        assert_equal length, root.context.transaction.length
        assert_equal [1], child.to_ruby
        assert_raises(StopIteration) { iterator.next }
        assert_equal [first], map.keys
        map.merge!(second => [2], first => [3])
        assert_raises(XitDB::ExpiredViewError) { child.size }
        assert_equal({ first => [3], second => [2] }, map.to_ruby)
        [Hash.new(0), {}.compare_by_identity].each do |input|
          assert_raises(XitDB::UnsupportedValueError) { map.merge!(input) }
        end
      end
    end
  end

  def test_text_alias_merge_retains_first_representation_and_last_value
    XitDB::Ruby.memory do |db|
      db.transaction do |root|
        root[:map] = XitDB.sorted_map(key: :string)
        map = root[:map]
        latin = "é".encode("ISO-8859-1")
        map.merge!(latin => [1], "é" => [2])
        assert_equal 1, map.size
        assert_equal [2], map[latin].to_ruby
        assert_equal Encoding::ISO_8859_1, map.keys.first.encoding
        child = map["é"]
        iterator = map.each
        iterator.next
        map.merge!("é" => [3])
        assert_raises(XitDB::ExpiredViewError) { child.size }
        assert_raises(StopIteration) { iterator.next }
        assert_equal [3], map[latin].to_ruby
        root[latin] = 1
        root["é"] = 2
        assert_equal 1, root[latin]
        assert_equal 2, root["é"]
      end
    end
  end

  def test_exact_sorted_envelopes_and_records
    XitDB::Ruby.memory do |db|
      db.transaction do |root|
        root[:map] = XitDB.sorted_map(key: :integer)
        root[:set] = XitDB.sorted_set(key: :string)
        root[:map][1] = nil
        root[:set].add("é".encode("ISO-8859-1"))
      end
      map = db.snapshot[:map]
      set = db.snapshot[:set]
      [[map, 0x52420105, 2], [set, 0x52420106, 1]].each do |view, marker, key_kind|
        envelope = XitDB::Core::ArrayList.new(view.context.cursor(view.slot))
        assert_equal 3, envelope.size
        assert_equal XitDB::Core::Slot.uint(marker), envelope.get(0)
        assert_equal XitDB::Core::Slot.uint(key_kind), envelope.get(1)
        assert_equal :sorted_map, envelope.get(2).tag
        bytes, stored = XitDB::Core::SortedMap.new(view.context.cursor(envelope.get(2))).each.first
        if view.equal?(map)
          assert_equal "02000000000000000101", bytes.unpack1("H*")
          record = XitDB::Core::ArrayList.new(view.context.cursor(stored))
          assert_equal 2, record.size
          assert_equal XitDB::Core::Slot.int(1), record.get(0)
          assert_equal XitDB::Core::Slot.null, record.get(1)
        else
          assert_equal "c3a9", bytes.unpack1("H*")
          assert_equal "01010a49534f2d383835392d3101e9", db.core.read_bytes(stored).bytes.unpack1("H*")
        end
      end
    end
  end

  def test_malformed_sorted_envelopes_and_original_keys_are_rejected
    XitDB::Ruby.memory do |db|
      db.transaction do |root|
        root[:map] = XitDB.sorted_map(key: :integer)
        root[:map][1] = [1]
        context = root.context
        [[0, XitDB::Core::Slot.uint(0)], [1, XitDB::Core::Slot.uint(9)],
         [1, XitDB::Core::Slot.int(2)], [2, XitDB::Core::Slot.null], [3, XitDB::Core::Slot.null]].each do |index, value|
          assert_raises(XitDB::InvalidValueError) do
            context.mutate([:map]) do |cursor|
              envelope = XitDB::Core::ArrayList.new(cursor)
              index == 3 ? envelope.append(value) : envelope.put(index, value)
              db.profile.container(cursor.slot, context: context, path: [:map])
            end
          end
        end
        %i[wrong_key wrong_size container_key raw_record].each do |defect|
          assert_raises(XitDB::InvalidValueError) do
            context.mutate([:map]) do |cursor|
              envelope = XitDB::Core::ArrayList.new(cursor)
              tree = XitDB::Core::SortedMap.new(context.cursor(envelope.get(2)))
              record = XitDB::Core::ArrayList.new(context.cursor(tree.get(ordered(1, :integer))))
              case defect
              when :wrong_key then record.put(0, XitDB::Core::Slot.int(2))
              when :wrong_size then record.append(XitDB::Core::Slot.null)
              when :container_key then record.put(0, record.get(1))
              end
              stored = defect == :raw_record ? XitDB::Core::Slot.int(1) : record.cursor.slot
              tree.put(ordered(1, :integer), value: stored)
              envelope.put(2, tree.cursor.slot)
              db.profile.container(cursor.slot, context: context, path: [:map]).lookup(1)
            end
          end
        end
        assert_equal({ 1 => [1] }, root[:map].to_ruby)
      end
    end
  end

  def test_sorted_size_rank_and_pages_do_not_scan_entries
    XitDB::Ruby.memory do |db|
      db.transaction do |root|
        root[:map] = XitDB.sorted_map(key: :integer)
        map = root[:map]
        512.times { |number| map[number] = number }
      end
      view = db.snapshot[:map]
      reads = 0
      original = db.core.method(:read_bytes)
      db.core.define_singleton_method(:read_bytes) do |*args, **options|
        reads += 1
        original.call(*args, **options)
      end
      assert_equal 512, view.size
      assert_operator reads, :<, 10
      reads = 0
      assert_equal 400, view.rank(400)
      assert_operator reads, :<, 40
      reads = 0
      assert_equal [[400, 400], [401, 401]], view.page(offset: 400, limit: 2).to_a
      assert_operator reads, :<, 40
      assert_empty view.from_index(512).to_a
      assert_empty view.page(offset: 0, limit: 0).to_a
      assert_raises(ArgumentError) { view.page(offset: 0, limit: -1) }
    end
  end

  def test_sorted_failed_storage_write_and_clear_restore_observed_values
    XitDB::Ruby.memory do |db|
      db.transaction do |root|
        root[:map] = XitDB.sorted_map(key: :integer)
        map = root[:map]
        map[1] = [1]
        map[2] = [2]
        child = map[1]
        iterator = map.each
        iterator.next
        transaction = root.context.transaction
        append = transaction.method(:append)
        failing = true
        transaction.define_singleton_method(:append) do |bytes|
          result = append.call(bytes)
          raise IOError, "injected sorted publication failure" if failing

          result
        end
        bound = transaction.length
        [-> { map[3] = [3] }, -> { map.clear }].each do |operation|
          assert_raises(IOError, &operation)
          assert_equal bound, transaction.length
          assert_equal [1], child.to_ruby
          assert_equal [1, 2], map.keys
        end
        assert_equal 2, iterator.next.first
        failing = false
        map.clear
        assert_raises(XitDB::ExpiredViewError) { child.size }
        assert_empty map
        map[4] = [4]
        assert_equal [4], map.keys
      end
    end
  end

  def test_sorted_count_failure_restores_tree_and_observed_values
    XitDB::Ruby.memory do |db|
      db.transaction do |root|
        root[:map] = XitDB.sorted_map(key: :integer)
        map = root[:map]
        map[1] = [1]
        map[2] = [2]
        child = map[1]
        transaction = root.context.transaction
        append = transaction.method(:append)
        failing = true
        transaction.define_singleton_method(:append) do |bytes|
          result = append.call(bytes)
          raise IOError, "injected sorted count failure" if failing && bytes.bytesize == 16

          result
        end
        bound = transaction.length
        [-> { map[3] = nil }, -> { map.delete(1) }].each do |operation|
          assert_raises(IOError, &operation)
          assert_equal bound, transaction.length
          assert_equal [1], child.to_ruby
          assert_equal [1, 2], map.keys
        end
        failing = false
        map[3] = nil
        assert_equal [1, 2, 3], map.keys
      end
    end
  end

  def test_sorted_file_reopen_preserves_exact_time_and_original_offset
    Dir.mktmpdir do |directory|
      path = File.join(directory, "sorted.xit")
      first = nil
      XitDB::Ruby.open(path) do |db|
        first = db.transaction do |root|
          root[:map] = XitDB.sorted_map(key: :time)
          root[:map][Time.at(Rational(1, 10**12)).getlocal(3600)] = ["old"]
        end.revision
        db.transaction { |root| root[:map][Time.at(Rational(1, 10**12)).utc] = ["new"] }
      end
      XitDB::Ruby.open(path, readonly: true) do |db|
        map = db.snapshot[:map]
        key = map.keys.first
        assert_equal Rational(1, 10**12), key.to_r
        assert_equal 3600, key.utc_offset
        assert key.frozen?
        assert_equal ["new"], map[key].to_ruby
        assert_equal ["old"], db.snapshot(revision: first)[:map][key].to_ruby
        assert_raises(XitDB::ReadOnlyError) { map[key] = 1 }
      end
    end
  end
end
