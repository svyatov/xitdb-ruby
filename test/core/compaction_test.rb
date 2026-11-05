# frozen_string_literal: true

# Regression tests for graph preservation, scratch storage bounds, and compaction cleanup after failures.

require "test_helper"
require "xitdb/ruby"
require "tmpdir"

# Covers graph preservation, scratch storage bounds, and compaction cleanup after failures.
# @api private
class CompactionTest < Minitest::Test
  Core = XitDB::Core

  # Checks short external bytes keep their representation and tag.
  def test_short_external_bytes_keep_their_representation_and_tag
    Dir.mktmpdir do |dir|
      source = Core::Database.memory
      source.transaction do |root|
        pointer = root.transaction.append("#{[3].pack("Q>")}abczz")
        root.replace(Core::Slot.new(tag: :bytes, value: pointer, full: true))
      end
      compacted = source.compact(to: File.join(dir, "target"))
      slot = compacted.root_cursor.slot

      assert_equal :bytes, slot.tag
      assert slot.full
      assert_equal "abc", compacted.read_bytes(slot).bytes
      assert_equal "zz", compacted.read_bytes(slot).format_tag
    ensure
      compacted&.close
      source&.close
    end
  end

  # Checks compaction preserves cycles tags and latest history.
  def test_compaction_preserves_cycles_tags_and_latest_history
    Dir.mktmpdir do |dir|
      source = Core::Database.open(File.join(dir, "source.xit"))
      source.transaction do |root|
        history = Core::ArrayList.new(root)
        history.append(Core::Slot.uint(10))
        tx = root.transaction
        pointer = tx.length
        tx.append([3, pointer + 16].pack("Q>Q>") + ("\0".b * Core::ArrayList::BLOCK_SIZE))
        graph = Core::Slot.new(tag: :array_list, value: pointer, full: true)
        bytes = source.bytes("a\0b".b, format_tag: "\xff\0".b)
        tx.write_at(pointer + 16, graph.to_bytes + bytes.to_bytes + bytes.to_bytes)
        history.append(graph)
      end
      before = source.root_cursor
      original = File.binread(File.join(dir, "source.xit"))
      compacted = source.compact(to: File.join(dir, "target.xit"))
      history = Core::ArrayList.new(compacted.root_cursor)

      assert_equal 1, history.size
      graph = history.get(0)

      assert_equal :array_list, graph.tag
      assert graph.full
      children = Core::ArrayList.new(history.cursor_at(0)).to_a

      assert_equal graph, children[0]
      assert_equal children[1], children[2]
      assert_equal "a\0b".b, compacted.read_bytes(children[1]).bytes
      assert_equal "\xff\0".b, compacted.read_bytes(children[1]).format_tag
      assert_equal 2, Core::ArrayList.new(before).size
      assert_equal original, File.binread(File.join(dir, "source.xit"))
      refute_equal source.header.file_id, compacted.header.file_id
    ensure
      compacted&.close
      source&.close
    end
  end

  # Checks public profiles keep latest history and source snapshots.
  def test_public_profiles_keep_latest_history_and_source_snapshots
    [XitDB, XitDB::Ruby].each do |api|
      Dir.mktmpdir do |dir|
        source = api.open(File.join(dir, "source.xit"))
        source.transaction { |root| root["value"] = "old" }
        before = source.snapshot
        source.transaction do |root|
          root["value"] = "latest"
          root["bytes"] = XitDB.bytes("opaque\0payload".b, format_tag: "xy")
          root["array"] = [1, nil, "three"]
        end
        original = File.binread(File.join(dir, "source.xit"))
        compacted = source.compact(to: File.join(dir, "target.xit"))

        assert_equal 1, compacted.history.size
        assert_equal "latest", compacted.snapshot["value"]
        assert_equal [1, nil, "three"], compacted.snapshot["array"].to_ruby
        assert_equal "opaque\0payload".b, compacted.snapshot["bytes"].bytes
        assert_equal "xy", compacted.snapshot["bytes"].format_tag
        assert_equal "old", before["value"]
        assert_equal original, File.binread(File.join(dir, "source.xit"))
        assert_equal source.core.header.hash_id, compacted.core.header.hash_id
        refute_equal source.core.header.file_id, compacted.core.header.file_id
        compacted.transaction { |root| root["new"] = 42 }

        assert_equal 42, compacted.snapshot["new"]
      ensure
        compacted&.close
        source&.close
      end
    end
  end

  # Checks that compaction preserves empty histories and raw inline roots.
  def test_empty_histories_and_arbitrary_inline_roots
    Dir.mktmpdir do |dir|
      source = Core::Database.memory(hash_id: "cust", hash_size: 11)
      values = [Core::Slot.new, Core::Slot.null, Core::Slot.uint((1 << 64) - 1),
                Core::Slot.int(-(1 << 63)), Core::Slot.float(-0.0), Core::Slot.float(Float::NAN)]
      values.each_with_index do |slot, index|
        source.transaction { |root| root.replace(slot) }
        compacted = source.compact(to: File.join(dir, index.to_s))

        assert_equal slot.to_bytes, compacted.root_cursor.slot.to_bytes
        assert_equal "cust", compacted.header.hash_id
        assert_equal 11, compacted.header.hash_size
        compacted.close
      end
      source.transaction do |root|
        root.replace(Core::Slot.new)
        Core::ArrayList.new(root)
      end
      compacted = source.compact(to: File.join(dir, "empty-history"))

      assert_empty compacted.root_cursor.slot
      assert_equal 62, compacted.committed_size
    ensure
      compacted&.close
      source&.close
    end
  end

  # Checks that sorted churn reclaims empty routes before compaction.
  def test_sorted_churn_reclaims_empty_routes_before_compaction
    configurations = [[Core::Database, Core::SortedMap], [Core::Database, Core::SortedSet],
                      [XitDB, XitDB.sorted_map], [XitDB, XitDB.sorted_set],
                      [XitDB::Ruby, XitDB.map], [XitDB::Ruby, XitDB.set],
                      [XitDB::Ruby, XitDB.sorted_map(key: :string)], [XitDB::Ruby, XitDB.sorted_set(key: :string)]]
    churn_counts = [0, 512]
    configurations.each do |api, declaration|
      sizes = churn_counts.map do |churn|
        Dir.mktmpdir do |dir|
          source = api.open(File.join(dir, "source"))
          source.transaction do |root|
            if api == Core::Database
              items = declaration.new(root)
              add = ->(key) { declaration == Core::SortedSet ? items.add(key) : items.put(key, value: Core::Slot.uint(1)) }
              remove = ->(key) { items.remove(key) }
            else
              root["items"] = declaration
              items = root["items"]
              add = ->(key) { items.kind.to_s.end_with?("set") ? items.add(key) : items[key] = 1 }
              remove = ->(key) { items.delete(key) }
            end
            add.call("live")
            (0...churn).each_slice(32) do |batch|
              batch.each do |index|
                add.call(format("%08d", index))
              end
              batch.each do |index| # rubocop:disable Style/CombinableLoops -- Populate every route before testing deletion and reclamation.
                remove.call(format("%08d", index))
              end

              assert_equal 1, items.size
            end
          end
          original = File.binread(File.join(dir, "source"))
          compacted = source.compact(to: File.join(dir, "target"))
          if api == Core::Database
            assert_equal ["live"], declaration.new(compacted.root_cursor).map(&:first)
          else
            expected = declaration.kind.to_s.end_with?("set") ? Set["live"] : { "live" => 1 }

            assert_equal expected, compacted.snapshot["items"].to_ruby
          end

          assert_equal original, File.binread(File.join(dir, "source"))
          File.size(File.join(dir, "target"))
        ensure
          compacted&.close
          source&.close
        end
      end

      assert_operator sizes.last, :<=, sizes.first + 1024,
                      "retained empty routes: #{api} #{declaration.inspect}: #{sizes}"
    end
  end

  # Checks same physical file and nonempty targets are unchanged.
  def test_same_physical_file_and_nonempty_targets_are_unchanged
    Dir.mktmpdir do |dir|
      path = File.join(dir, "source")
      source = Core::Database.open(path)
      hardlink = File.join(dir, "hardlink")
      symlink = File.join(dir, "symlink")
      File.link(path, hardlink)
      File.symlink(path, symlink)
      [path, hardlink, symlink].each do |target|
        original = File.binread(path)
        assert_raises(ArgumentError) { source.compact(to: target) }
        assert_equal original, File.binread(path)
      end
      target = File.join(dir, "occupied")
      File.binwrite(target, "user data")
      assert_raises(ArgumentError) { source.compact(to: target) }
      assert_equal "user data", File.binread(target)
      File.binwrite(target, "")
      compacted = source.compact(to: target)

      assert_empty compacted.root_cursor.slot
      compacted.close
      original = File.binread(target)
      assert_raises(ArgumentError) { source.compact(to: target) }
      assert_equal original, File.binread(target)
    ensure
      source&.close
    end
  end

  # Checks that offset map spills exact keys and removes its scratch file.
  def test_offset_map_spills_exact_keys_and_removes_its_scratch_file
    offsets = Core::OffsetMap.new
    16_384.times { |i| offsets.store(i, i + 50) }

    assert_equal 16_384, offsets.peak_cache_size
    assert_nil offsets.instance_variable_get(:@temporary)
    offsets.store((1 << 64) - 1, 999)
    path = offsets.instance_variable_get(:@temporary).path

    assert File.file?(path)
    assert_equal 16_384, offsets.peak_cache_size
    assert_equal 0, offsets.instance_variable_get(:@cache).size
    [0, 1, 16_383].each { |i| assert_equal i + 50, offsets.fetch(i) }
    assert_equal 999, offsets.fetch((1 << 64) - 1)
    assert_nil offsets.fetch(16_384)
    offsets.store(0, 123)

    assert_equal 123, offsets.fetch(0)
    offsets.close

    refute_path_exists path
    offsets.close
    assert_raises(XitDB::ClosedError) { offsets.fetch(0) }
  ensure
    offsets&.close
  end

  # Checks copy failure restores empty target and preserves source.
  def test_copy_failure_restores_empty_target_and_preserves_source
    Dir.mktmpdir do |dir|
      path = File.join(dir, "source")
      source = Core::Database.open(path)
      source.transaction { |root| root.replace(Core::Slot.new(tag: :bytes, value: (1 << 64) - 1)) }
      original = File.binread(path)
      target = File.join(dir, "target")
      File.binwrite(target, "")
      assert_raises(XitDB::CorruptionError) { source.compact(to: target) }
      assert_equal 0, File.size(target)
      assert_equal original, File.binread(path)
      source.transaction { |root| root.replace(Core::Slot.uint(7)) }
      compacted = source.compact(to: target)

      assert_equal 7, compacted.root_cursor.slot.value
    ensure
      compacted&.close
      source&.close
    end
  end

  # Checks offset map close discards pending bytes after flush failure.
  def test_offset_map_close_discards_pending_bytes_after_flush_failure
    offsets = Core::OffsetMap.new
    16_385.times { |i| offsets.store(i, i + 50) }
    store = offsets.instance_variable_get(:@store)
    file = store.instance_variable_get(:@file)
    path = offsets.instance_variable_get(:@temporary).path

    assert_operator store.instance_variable_get(:@pending).bytesize, :>, 0
    file.define_singleton_method(:pwrite) { |*| raise Errno::ENOSPC }
    assert_raises(Errno::ENOSPC) { store.flush }
    offsets.close

    assert_predicate store, :closed?
    assert_predicate file, :closed?
    refute_path_exists path
    assert_raises(XitDB::ClosedError) { offsets.fetch(0) }
    assert_raises(XitDB::ClosedError) { offsets.store(0, 1) }
    offsets.close
  ensure
    file&.singleton_class&.remove_method(:pwrite)
    store&.close unless store&.closed?
    offsets&.close
  end

  # Checks offset map cleanup retry after descriptor close failure.
  def test_offset_map_cleanup_retry_after_descriptor_close_failure
    offsets = Core::OffsetMap.new
    16_385.times { |i| offsets.store(i, i + 50) }
    store = offsets.instance_variable_get(:@store)
    file = store.instance_variable_get(:@file)
    path = offsets.instance_variable_get(:@temporary).path
    original = file.method(:close)
    failure = IOError.new("descriptor close failed")
    failing = true
    file.define_singleton_method(:close) do
      if failing
        failing = false
        raise failure
      end
      original.call
    end

    assert_same failure, assert_raises(IOError) { offsets.close }
    refute_predicate store, :closed?
    refute_predicate file, :closed?
    refute_path_exists path
    assert_raises(XitDB::ClosedError) { offsets.fetch(0) }
    assert_raises(XitDB::ClosedError) { offsets.store(0, 1) }
    offsets.close

    assert_predicate store, :closed?
    assert_predicate file, :closed?
    offsets.close
  ensure
    file&.singleton_class&.remove_method(:close)
    store&.close unless store&.closed?
    offsets&.close
  end

  # Checks ruby codecs are opaque and copied configuration is independent.
  def test_ruby_codecs_are_opaque_and_copied_configuration_is_independent
    type = Struct.new(:bytes)
    calls = []
    codec = XitDB::Ruby::Codec.new(id: "test/value", type: type,
                                   dump: lambda { |value|
                                     calls << :dump
                                     value.bytes
                                   },
                                   load: lambda { |bytes|
                                     calls << :load
                                     type.new(bytes)
                                   })
    Dir.mktmpdir do |dir|
      source = XitDB::Ruby.memory(codecs: [codec])
      unknown = "\x01\x0a\x07unknown\x03\x00\xffx".b
      source.transaction do |root|
        root[:known] = type.new("payload\0".b)
        root[:unknown] = XitDB.bytes(unknown, format_tag: "rb")
      end
      calls.clear
      compacted = source.compact(to: File.join(dir, "target"))

      assert_empty calls
      refute_same source.profile, compacted.profile
      refute_same source.profile.instance_variable_get(:@registry), compacted.profile.instance_variable_get(:@registry)
      assert_same codec, compacted.profile.codecs.first
      assert_equal "payload\0".b, compacted.snapshot[:known].bytes
      assert_equal [:load], calls
      assert_equal unknown, compacted.snapshot[:unknown].bytes
      assert_equal "unknown", compacted.snapshot[:unknown].codec_id
    ensure
      compacted&.close
      source&.close
    end
  end

  # Checks that compaction copies every raw collection layout, record tag, and large byte payload.
  def test_all_raw_collection_and_record_tags_and_large_bytes
    Dir.mktmpdir do |dir|
      compacted = nil
      source = Core::Database.memory
      values = {}
      source.transaction do |root|
        tx = root.transaction
        values[:bytes] = source.bytes("x\0".b * 70_000, format_tag: "zz")
        values[:short_bytes] = source.bytes("sixsix", format_tag: "\xff\0".b)
        values[:kv_pair] = Core::Slot.new(
          tag: :kv_pair,
          value: tx.append(("h" * 20) + values[:short_bytes].to_bytes + values[:bytes].to_bytes), full: true
        )
        values[:sorted_kv_pair] = Core::Slot.new(
          tag: :sorted_kv_pair, value: tx.append(values[:short_bytes].to_bytes + values[:bytes].to_bytes)
        )
        values[:index] = Core::Slot.new(
          tag: :index, value: tx.append(values[:kv_pair].to_bytes + values[:sorted_kv_pair].to_bytes + ("\0".b * 126))
        )
        Core::HashMap::TAGS.each do |tag|
          cursor = tx.cursor(slot: Core::Slot.new)
          map = Core::HashMap.new(cursor, counted: tag.to_s.start_with?("counted"), set: tag.to_s.end_with?("set"))
          17.times { |i| map.put([i].pack("Q>").rjust(20, "\0"), key: Core::Slot.uint(i), value: values[:bytes]) }
          values[tag] = cursor.slot
        end
        %i[linked_array_list sorted_map sorted_set].each do |tag|
          cursor = tx.cursor(slot: Core::Slot.new)
          if tag == :linked_array_list
            list = Core::LinkedArrayList.new(cursor)
            257.times { list.append(values[:bytes]) }
          else
            map = Core::SortedMap.new(cursor, set: tag == :sorted_set)
            257.times { |i| map.put(format("key-%04d-long", i), value: values[:bytes]) }
          end
          values[tag] = cursor.slot
        end
      end
      max_read = 0
      original_read = source.method(:read_at)
      source.define_singleton_method(:read_at) do |offset, size, bound:|
        max_read = [max_read, size].max
        original_read.call(offset, size, bound: bound)
      end
      values.each do |tag, slot|
        source.transaction { |root| root.replace(slot) }
        compacted = source.compact(to: File.join(dir, tag.to_s))
        root = compacted.root_cursor

        assert_equal tag, root.slot.tag
        assert_equal slot.full, root.slot.full
        case tag
        when :bytes, :short_bytes
          expected = tag == :bytes ? "x\0".b * 70_000 : "sixsix"

          assert_equal expected, root.read_bytes.bytes
          assert_equal(tag == :bytes ? "zz" : "\xff\0".b, root.read_bytes.format_tag)
        when :index, :kv_pair, :sorted_kv_pair
          pair = tag == :index ? Core::Slot.parse(compacted.read_at(root.slot.value, 9, bound: root.bound)) : root.slot
          offset = pair.value + (pair.tag == :kv_pair ? 20 : 0)
          value = Core::Slot.parse(compacted.read_at(offset + 9, 9, bound: root.bound))

          assert_equal "x\0".b * 70_000, compacted.read_bytes(value).bytes
        when *Core::HashMap::TAGS
          map = Core::HashMap.from_cursor(root)

          assert_equal 17, map.size
          slots = map.each_entry.map { |_hash, _key, value| value }

          assert_equal 1, slots.map(&:value).uniq.size
          assert_equal "x\0".b * 70_000, compacted.read_bytes(slots.first).bytes
        when :linked_array_list
          list = Core::LinkedArrayList.new(root)

          assert_equal 257, list.size
          assert_equal 1, list.map(&:value).uniq.size
          assert_equal "x\0".b * 70_000, compacted.read_bytes(list.get(256)).bytes
        else
          map = Core::SortedMap.new(root)

          assert_equal 257, map.size
          assert_equal "key-0256-long", map.at(256).first
          assert_equal "x\0".b * 70_000, compacted.read_bytes(map.get("key-0256-long")).bytes
        end
        compacted.close
      end

      assert_equal 64 * 1024, max_read
    ensure
      compacted&.close
      source&.close
    end
  end

  # Checks that shared partial array blocks drop invisible tails.
  def test_shared_partial_array_blocks_drop_invisible_tails
    Dir.mktmpdir do |dir|
      source = Core::Database.memory
      source.transaction do |root|
        tx = root.transaction
        pointer = tx.append(Core::Slot.uint(11).to_bytes + Core::Slot.uint(22).to_bytes +
          Core::Slot.new(tag: :bytes, value: (1 << 64) - 1).to_bytes + ("\0".b * 117))
        short = Core::Slot.new(tag: :array_list, value: tx.append([1, pointer].pack("Q>Q>")))
        long = Core::Slot.new(tag: :array_list, value: tx.append([2, pointer].pack("Q>Q>")))
        holder = Core::LinkedArrayList.new(root)
        holder.append(short).append(long)
      end
      compacted = source.compact(to: File.join(dir, "target"))
      holder = Core::LinkedArrayList.new(compacted.root_cursor)

      assert_equal [11], Core::ArrayList.new(holder.cursor_at(0)).map(&:value)
      assert_equal [11, 22], Core::ArrayList.new(holder.cursor_at(1)).map(&:value)
      pointers = holder.map do |slot|
        compacted.read_at(slot.value + 8, 8, bound: compacted.committed_size).unpack1("Q>")
      end

      refute_equal pointers[0], pointers[1]
      assert_equal "\0".b * 135, compacted.read_at(pointers[0] + 9, 135, bound: compacted.committed_size)
      assert_equal "\0".b * 126, compacted.read_at(pointers[1] + 18, 126, bound: compacted.committed_size)
    ensure
      compacted&.close
      source&.close
    end
  end

  # Checks that deep cycle spills without recursion and interrupt cleans scratch.
  def test_deep_cycle_spills_without_recursion_and_interrupt_cleans_scratch
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "source")
      source = Core::Database.open(source_path)
      count = 16_400
      first = nil
      source.transaction do |root|
        tx = root.transaction
        first = tx.length
        count.times do |i|
          pointer = i == count - 1 ? first : first + ((i + 1) * 144)
          tx.append(Core::Slot.new(tag: :index, value: pointer).to_bytes + ("\0".b * 135))
        end
        root.replace(Core::Slot.new(tag: :index, value: first))
      end
      original = File.binread(source_path)
      maps = []
      original_new = Core::OffsetMap.method(:new)
      Core::OffsetMap.define_singleton_method(:new) { original_new.call.tap { |map| maps << map } }
      compacted = source.compact(to: File.join(dir, "success"))
      pointer = compacted.root_cursor.slot.value
      count.times { pointer = Core::Slot.parse(compacted.read_at(pointer, 9, bound: compacted.committed_size)).value }

      assert_equal compacted.root_cursor.slot.value, pointer
      assert_equal 16_384, maps.first.peak_cache_size
      assert_raises(XitDB::ClosedError) { maps.first.fetch(first) }
      scratch_paths = []
      scratch_flush_errors = []
      scratch_failure = IOError.new("scratch write failed")
      interrupted = Interrupt.new("copy interrupted")
      original_read = source.method(:read_at)
      source.define_singleton_method(:read_at) do |offset, size, bound:|
        if offset == first + ((count - 1) * 144)
          scratch_paths << maps.last.instance_variable_get(:@temporary).path
          scratch_store = maps.last.instance_variable_get(:@store)
          scratch_file = scratch_store.instance_variable_get(:@file)
          scratch_file.define_singleton_method(:pwrite) { |*| raise scratch_failure }
          begin
            scratch_store.flush
          rescue IOError => e
            scratch_flush_errors << e
          end
          raise interrupted
        end
        original_read.call(offset, size, bound: bound)
      end
      target = File.join(dir, "interrupted")

      assert_same interrupted, assert_raises(Interrupt) { source.compact(to: target) }
      assert_equal 0, File.size(target)
      assert_equal 16_384, maps.last.peak_cache_size
      assert_equal 1, scratch_paths.size
      refute_path_exists scratch_paths.first
      assert_same scratch_failure, scratch_flush_errors.fetch(0)
      assert_predicate maps.last.instance_variable_get(:@store), :closed?
      assert_predicate maps.last.instance_variable_get(:@store).instance_variable_get(:@file), :closed?
      assert_raises(XitDB::ClosedError) { maps.last.fetch(first) }
      assert_equal original, File.binread(source_path)
    ensure
      maps&.each do |map|
        scratch_store = map.instance_variable_get(:@store)
        next unless scratch_store && !scratch_store.closed?

        scratch_store.instance_variable_get(:@file).singleton_class.remove_method(:pwrite)
        scratch_store.close
      end
      Core::OffsetMap.singleton_class.remove_method(:new) if original_new
      compacted&.close
      source&.close
    end
  end

  # Checks that target initialization rechecks empty state under lock.
  def test_target_initialization_rechecks_empty_state_under_lock
    Dir.mktmpdir do |dir|
      source = Core::Database.memory
      target = File.join(dir, "target")
      configure = lambda do |store|
        original = store.method(:with_exclusive_lock)
        store.define_singleton_method(:with_exclusive_lock) do |**options, &block|
          File.binwrite(target, "competing writer")
          original.call(**options, &block)
        end
      end

      with_target_store(target, configure) { assert_raises(ArgumentError) { source.compact(to: target) } }
      assert_equal "competing writer", File.binread(target)
    ensure
      source&.close
    end
  end

  # Checks failed copy cleanup preserves competing generation or root.
  def test_failed_copy_cleanup_preserves_competing_generation_or_root
    %i[generation root].each do |change|
      Dir.mktmpdir do |dir|
        source = Core::Database.memory
        source.transaction { |root| root.replace(Core::Slot.new(tag: :bytes, value: (1 << 64) - 1)) }
        target = File.join(dir, "target")
        configure = lambda do |store|
          original = store.method(:with_exclusive_lock)
          lock_count = 0
          store.define_singleton_method(:with_exclusive_lock) do |**options, &block|
            lock_count += 1
            if lock_count == 3
              other = Core::FileStore.open(target)
              other.with_exclusive_lock { other.truncate(0) } if change == :generation
              competing = Core::Database.new(store: other)
              competing.transaction { |root| root.replace(Core::Slot.uint(99)) } if change == :root
              competing.close
            end
            original.call(**options, &block)
          end
        end

        with_target_store(target, configure) { assert_raises(XitDB::CorruptionError) { source.compact(to: target) } }
        Core::Database.open(target, readonly: true) do |reader|
          if change == :generation
            assert_empty reader.root_cursor.slot
            assert_equal 62, reader.committed_size
          else
            assert_equal 99, reader.root_cursor.slot.value
          end
        end
      ensure
        source&.close
      end
    end
  end

  # Checks target commit faults preserve outcomes and uncertain output.
  def test_target_commit_faults_preserve_outcomes_and_uncertain_output
    [3, 4].each do |failed_sync|
      Dir.mktmpdir do |dir|
        source = Core::Database.memory
        source.transaction { |root| root.replace(Core::Slot.uint(7)) }
        target = File.join(dir, "target")
        configure = lambda do |store|
          original = store.method(:sync)
          syncs = 0
          store.define_singleton_method(:sync) do
            syncs += 1
            raise IOError, "sync failed" if syncs == failed_sync

            original.call
          end
        end
        with_target_store(target, configure) do
          error = assert_raises(XitDB::CommitError) { source.compact(to: target) }
          assert_equal(failed_sync == 3 ? :not_committed : :unknown, error.outcome)
        end
        if failed_sync == 3
          assert_equal 0, File.size(target)
        else
          Core::Database.open(target, readonly: true) { |reader| assert_equal 7, reader.root_cursor.slot.value }
        end
      ensure
        source&.close
      end
    end
  end

  # Checks competing commit before copy is rejected without overwriting.
  def test_competing_commit_before_copy_is_rejected_without_overwriting
    [Core::Slot.uint(99), Core::Slot.new].each do |competing_slot|
      Dir.mktmpdir do |dir|
        source = Core::Database.memory
        source.transaction { |root| root.replace(Core::Slot.uint(7)) }
        target = File.join(dir, "target")
        configure = lambda do |store|
          original = store.method(:with_exclusive_lock)
          lock_count = 0
          store.define_singleton_method(:with_exclusive_lock) do |**options, &block|
            lock_count += 1
            if lock_count == 2
              Core::Database.open(target) { |competing| competing.transaction { |root| root.replace(competing_slot) } }
            end
            original.call(**options, &block)
          end
        end

        with_target_store(target, configure) { assert_raises(ArgumentError) { source.compact(to: target) } }
        Core::Database.open(target, readonly: true) { |reader| assert_equal competing_slot, reader.root_cursor.slot }
      ensure
        source&.close
      end
    end
  end

  # Checks failed target initialization restores only known aborts.
  def test_failed_target_initialization_restores_only_known_aborts
    [1, 2].each do |failed_sync|
      Dir.mktmpdir do |dir|
        source = Core::Database.memory
        target = File.join(dir, "target")
        configure = lambda do |store|
          original = store.method(:sync)
          syncs = 0
          store.define_singleton_method(:sync) do
            syncs += 1
            raise IOError, "initialization sync failed" if syncs == failed_sync

            original.call
          end
        end
        with_target_store(target, configure) do
          error = assert_raises(XitDB::CommitError) { source.compact(to: target) }
          assert_equal(failed_sync == 1 ? :not_committed : :unknown, error.outcome)
        end
        assert_equal(failed_sync == 1 ? 0 : 62, File.size(target))
      ensure
        source&.close
      end
    end
  end

  # Checks cleanup error does not replace copy error.
  def test_cleanup_error_does_not_replace_copy_error
    Dir.mktmpdir do |dir|
      source = Core::Database.memory
      source.transaction { |root| root.replace(Core::Slot.new(tag: :bytes, value: (1 << 64) - 1)) }
      target = File.join(dir, "target")
      configure = lambda do |store|
        original = store.method(:close)
        store.define_singleton_method(:close) do
          original.call
          raise Interrupt, "cleanup interrupted"
        end
      end

      with_target_store(target, configure) { assert_raises(XitDB::CorruptionError) { source.compact(to: target) } }
      assert_equal 0, File.size(target)
    ensure
      source&.close
    end
  end

  private

  # Intercepts target-store opening to install the requested fault.
  # @param path [String] destination path to intercept
  # @param configure [Proc] callback that configures the target store
  # @yield executes the operation under test
  # @return [Object] block result
  def with_target_store(path, configure)
    original = Core::FileStore.method(:open)
    selected = false
    Core::FileStore.singleton_class.remove_method(:open)
    Core::FileStore.define_singleton_method(:open) do |target, **options|
      store = original.call(target, **options)
      if target == path && !selected
        selected = true
        configure.call(store)
      end
      store
    end
    yield
  ensure
    if original
      Core::FileStore.singleton_class.remove_method(:open)
      Core::FileStore.define_singleton_method(:open, original)
    end
  end
end
