# frozen_string_literal: true

require "test_helper"
require "xitdb/ruby"
require "tmpdir"

class ConversionTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("xitdb-conversion-")
    @handles = []
  end

  def teardown
    @handles.reverse_each { |db| db.close unless db.closed? }
    FileUtils.remove_entry(@directory)
  end

  def test_explicit_native_to_portable_transform_and_collision
    native = track(XitDB::Ruby.memory)
    native.transaction { |root| root[:name] = "Ada" }
    transform = ->(value:, path:, role:) { value.is_a?(Symbol) ? value.to_s : value }
    target = track(native.convert(to: path("target"), profile: :portable, transform: transform))
    assert_equal "Ada", target.snapshot["name"]
    native.transaction { |root| root["name"] = "Other" }
    assert_raises(XitDB::KeyCollisionError) do
      native.convert(to: path("collision"), profile: :portable, transform: transform)
    end
    assert_equal 0, File.size(path("collision"))
    assert_equal "Other", native.snapshot["name"]
  end

  def test_histories_and_both_directions_without_materialization
    source = track(XitDB.memory)
    source.transaction { |root| root["data"] = [1, {"name" => "Ada"}, Set["a", "b"]] }
    source.transaction { |root| root["number"] = 2 }
    guard = TracePoint.new(:call) do |event|
      raise "whole-root materialization" if event.method_id == :to_ruby
    end
    target = guard.enable { track(source.convert(to: path("ruby"), profile: :ruby)) }
    assert_equal 2, target.history.size
    assert_nil target.history[0]["number"]
    assert_equal [1, {"name" => "Ada"}, Set["a", "b"]], target.snapshot["data"].to_ruby
    latest = track(target.convert(to: path("latest"), profile: :portable, history: :latest))
    assert_equal 1, latest.history.size
    assert_equal 2, latest.snapshot["number"]
    assert_equal "sha1", latest.core.header.hash_id
    refute_equal source.core.header.file_id, target.core.header.file_id
  ensure
    guard&.disable
  end

  def test_empty_history_and_invalid_history_selection
    source = track(XitDB.memory)
    target = track(source.convert(to: path("empty"), profile: :ruby))
    assert_equal 0, target.history.size
    assert_empty target.snapshot
    assert_raises(ArgumentError) { source.convert(to: path("invalid"), profile: :portable, history: :first) }
    refute File.exist?(path("invalid"))
  end

  def test_path_dependent_transform_and_captured_source_history
    source = track(XitDB.memory)
    source.transaction do |root|
      root["left"] = {"n" => 1}
      root["right"] = root["left"]
    end
    source.transaction { |root| root["version"] = 2 }
    calls = []
    appended = false
    transform = lambda do |value:, path:, role:|
      calls << [path, role]
      assert path.frozen?
      unless appended
        appended = true
        Thread.new { source.transaction { |root| root["version"] = 3 } }.value
      end
      role == :value && path.last == "n" ? path.first : value
    end
    target = track(source.convert(to: path("captured"), profile: :ruby, transform: transform))
    assert_equal 2, target.history.size
    assert_equal 3, source.history.size
    assert_equal "left", target.snapshot.dig("left", "n")
    assert_equal "right", target.snapshot.dig("right", "n")
    assert_equal 2, target.snapshot["version"]
    assert_includes calls, [["left", "n"], :value]
    assert_includes calls, [["left", "n"], :key]
  end

  def test_destination_conflicts_and_callback_failure_preserve_data
    source = track(XitDB.open(path("source")))
    source.transaction { |root| root["n"] = 1 }
    original = File.binread(path("source"))
    File.link(path("source"), path("alias"))
    [path("source"), path("alias")].each do |target|
      assert_raises(ArgumentError) { source.convert(to: target, profile: :ruby) }
    end
    assert_equal original, File.binread(path("source"))
    File.binwrite(path("nonempty"), "keep me")
    assert_raises(ArgumentError) { source.convert(to: path("nonempty"), profile: :portable) }
    assert_equal "keep me", File.binread(path("nonempty"))
    failure = StopIteration.new("conversion callback failed")
    error = assert_raises(StopIteration) do
      source.convert(to: path("failed"), profile: :ruby, transform: ->(**) { raise failure })
    end
    assert_same failure, error
    assert_equal 0, File.size(path("failed"))
    assert_equal 1, source.snapshot["n"]
  end

  def test_configured_profiles_opaque_values_and_unknown_codecs
    source = track(XitDB.memory(hash: :sha256))
    source.transaction { |root| root["opaque"] = XitDB::Core::ByteValue.new("payload", format_tag: "zz") }
    portable = track(source.convert(to: path("same"), profile: :portable))
    assert_equal 32, portable.core.header.hash_size
    configured = XitDB::Profiles::Portable.new(hasher: XitDB::Core::Hasher.sha512)
    custom = track(source.convert(to: path("configured"), profile: configured))
    assert_equal 64, custom.core.header.hash_size
    refute_same configured, custom.profile
    native = track(source.convert(to: path("opaque"), profile: :ruby))
    assert_equal "zz", native.snapshot["opaque"].format_tag
    assert_equal "payload", native.snapshot["opaque"].bytes
    payload = "\x01\x0a\x09vendor/v1\x03abc".b
    unknown = XitDB::Ruby::EncodedValue.new(codec_id: "vendor/v1", bytes: payload)
    native.transaction { |root| root["custom"] = unknown }
    clone = track(native.convert(to: path("unknown"), profile: :ruby))
    refute_same native.profile.codecs, clone.profile.codecs
    assert_equal payload, clone.snapshot["custom"].bytes
    assert_raises(XitDB::UnsupportedValueError) { native.convert(to: path("unsupported"), profile: :portable) }
    transformed = track(native.convert(to: path("transformed"), profile: :portable,
                                       transform: ->(value:, **) { XitDB::Ruby::EncodedValue === value ? "unknown" : value }))
    assert_equal "unknown", transformed.snapshot["custom"]
    source.transaction { |root| root["reserved"] = XitDB::Core::ByteValue.new("\x01\x03\x01", format_tag: "rb") }
    assert_raises(XitDB::UnsupportedValueError) { source.convert(to: path("reserved"), profile: :ruby) }
  end

  def test_copy_from_cross_file_paths_and_atomic_rollback
    source = track(XitDB::Ruby.memory)
    source.transaction { |root| root[:person] = {name: "Ada", scores: [1, 2]} }
    destination = track(XitDB.memory)
    old = nil
    expired = nil
    snapshot = destination.transaction do |root|
      root["people"] = [{"old" => 1}]
      old = root["people"][0]
      expired = root.context
      copied = root.context.copy_from(source.snapshot[:person], at: ["people", -1],
                                      transform: ->(value:, **) { Symbol === value ? value.to_s : value })
      assert_equal "Ada", copied["name"]
      assert_raises(XitDB::ExpiredViewError) { old.size }
      assert_raises(XitDB::UnsupportedValueError) { root.context.copy_from(source.snapshot, at: ["bad"]) }
      refute root.key?("bad")
      assert_raises(XitDB::ExpiredViewError) { root.context.copy_from(source.snapshot, at: ["absent", "child"]) }
    end
    source.close
    assert_equal "Ada", snapshot["people"][0]["name"]
    assert_equal [1, 2], snapshot["people"][0]["scores"].to_ruby
    assert_raises(XitDB::ReadOnlyError) { snapshot.context.copy_from(snapshot, at: ["x"]) }
    assert_raises(XitDB::ExpiredViewError) { expired.copy_from(snapshot, at: ["x"]) }
  end

  def test_large_strings_and_opaque_bytes_are_streamed_without_scalar_allocation
    source = track(XitDB.memory)
    utf8 = "a" * 65_535 + "é" + "b" * 140_000
    binary = "\xff\x00".b * 110_000
    source.transaction do |root|
      root["utf8"] = utf8
      root["binary"] = binary
      root["opaque"] = XitDB::Core::ByteValue.new(binary, format_tag: "zz")
    end
    enforce_bounded_reads(source.core)
    native = track(source.convert(to: path("streamed"), profile: :ruby))
    assert_equal utf8, native.snapshot["utf8"]
    assert_equal Encoding::UTF_8, native.snapshot["utf8"].encoding
    assert_equal binary, native.snapshot["binary"]
    assert_equal Encoding::BINARY, native.snapshot["binary"].encoding
    assert_equal binary, native.snapshot["opaque"].bytes
    native.transaction { |root| root["encoded"] = "é".encode(Encoding::UTF_16LE) * 100_000 }
    enforce_bounded_reads(native.core)
    portable = track(native.convert(to: path("streamed-back"), profile: :portable))
    assert_equal binary, portable.snapshot["binary"]
    assert_equal "é".encode(Encoding::UTF_16LE).b * 100_000, portable.snapshot["encoded"].b
    clone = track(native.convert(to: path("streamed-native"), profile: :ruby))
    assert_equal Encoding::UTF_16LE, clone.snapshot["encoded"].encoding
  end

  def test_copy_slice_root_replacement_and_source_relative_transform_paths
    source = track(XitDB.memory)
    source.transaction { |root| root["numbers"] = [10, 20, 30, 40] }
    destination = track(XitDB::Ruby.memory)
    calls = []
    destination.transaction do |root|
      root.context.copy_from(source.snapshot["numbers"][1, 2], at: [:slice],
                             transform: ->(value:, path:, **) { calls << path; value + 1 })
      assert_equal [21, 31], root[:slice].to_ruby
      assert_equal [[0], [1]], calls
      assert_raises(XitDB::ProfileMismatchError) { root.context.copy_from(source.snapshot["numbers"], at: []) }
      child = root[:slice]
      root.context.copy_from(source.snapshot, at: [])
      assert_equal [10, 20, 30, 40], root["numbers"].to_ruby
      assert_raises(XitDB::ExpiredViewError) { child.size }
      refute root.key?(:slice)
    end
  end

  def test_copy_callbacks_cannot_mutate_either_active_transaction_or_leak_foreign_views
    source = track(XitDB.memory)
    destination = track(XitDB::Ruby.memory)
    source.transaction do |source_root|
      source_root["n"] = 1
      destination.transaction do |root|
        [source_root, root].each do |mutating|
          assert_raises(XitDB::TransactionStateError) do
            root.context.copy_from(source_root, at: ["copy"], transform: ->(value:, **) { mutating["bad"] = 9; value })
          end
          assert_empty root
          refute source_root.key?("bad")
        end
        assert_raises(XitDB::ForeignValueError) do
          root.context.copy_from(source_root, at: ["copy"], transform: ->(value:, role:, **) { role == :value ? source_root : value })
        end
        assert_empty root
        assert_raises(XitDB::UnsupportedValueError) do
          root.context.copy_from(source_root, at: ["copy"], transform: ->(value:, role:, **) { role == :value ? Class.new(String).new("bad") : value })
        end
        assert_empty root
        root.context.copy_from(source_root, at: ["copy"], transform: ->(value:, role:, **) { role == :value ? [value, 2] : value })
        assert_equal [1, 2], root["copy"]["n"].to_ruby
      end
    end
  end

  def test_sorted_kinds_set_collisions_and_explicit_key_transform
    native = track(XitDB::Ruby.memory)
    native.transaction do |root|
      root["sorted"] = XitDB.sorted_map(key: :integer)
      root["sorted"][2] = "two"
      root["sorted"][1] = "one"
      root["set"] = Set[:name, "name"]
    end
    assert_raises(XitDB::UnsupportedValueError) { native.convert(to: path("numeric"), profile: :portable) }
    assert_raises(XitDB::KeyCollisionError) do
      native.convert(to: path("set-collision"), profile: :portable,
                     transform: ->(value:, role:, **) { role == :key ? value.to_s : value })
    end
    native.transaction { |root| root.delete("set") }
    target = track(native.convert(to: path("sorted"), profile: :portable, history: :latest,
                                   transform: ->(value:, role:, **) { role == :key ? value.to_s : value }))
    assert_equal :sorted_map, target.snapshot["sorted"].kind
    assert_equal ["1", "2"], target.snapshot["sorted"].keys
    target.transaction do |root|
      root["sorted"]["\xff".b] = "invalid UTF-8 key"
    end
    assert_raises(XitDB::UnsupportedEncodingError) { target.convert(to: path("invalid-key"), profile: :ruby) }
  end

  def test_transformed_key_is_owned_before_value_callbacks
    source = track(XitDB.memory)
    source.transaction { |root| root["name"] = 1 }
    key = +"name"
    target = track(source.convert(to: path("owned-key"), profile: :ruby,
      transform: lambda { |value:, role:, **|
        if role == :key
          key
        else
          key.replace("changed")
          value
        end
      }))
    assert_equal 1, target.snapshot["name"]
    refute target.snapshot.key?("changed")
  end

  def test_competing_target_commits_are_rejected_even_for_empty_source
    [false, true].each do |populated|
      source = track(XitDB.memory)
      source.transaction { |root| root["source"] = 1 } if populated
      target_path = path("race-#{populated}")
      raced = false
      configure = lambda do |store|
        lock = store.method(:with_exclusive_lock)
        count = 0
        store.define_singleton_method(:with_exclusive_lock) do |**options, &block|
          count += 1
          if count == 2
            raced = true
            XitDB.open(target_path) { |other| other.transaction { |root| root["competitor"] = 99 } }
          end
          lock.call(**options, &block)
        end
      end
      with_target_store(target_path, configure) do
        assert_raises(ArgumentError) { source.convert(to: target_path, profile: :portable) }
      end
      assert raced
      XitDB.open(target_path) { |other| assert_equal 99, other.snapshot["competitor"] }
    end
  end

  def test_failed_publication_retains_outcome_and_closes_owned_store
    [1, 2, 3, 4].each do |failed_sync|
      source = track(XitDB.memory)
      source.transaction { |root| root["n"] = 7 }
      target_path = path("sync-#{failed_sync}")
      captured = nil
      failure = IOError.new("conversion sync failed")
      configure = lambda do |store|
        captured = store
        sync = store.method(:sync)
        count = 0
        store.define_singleton_method(:sync) do
          count += 1
          raise failure if count == failed_sync

          sync.call
        end
      end
      with_target_store(target_path, configure) do
        error = assert_raises(XitDB::CommitError) { source.convert(to: target_path, profile: :portable) }
        assert_equal(failed_sync.odd? ? :not_committed : :unknown, error.outcome)
        assert_same failure, error.cause
      end
      assert captured.closed?
      assert captured.instance_variable_get(:@file).closed?
      if failed_sync.odd?
        assert_equal 0, File.size(target_path)
      else
        assert_operator File.size(target_path), :>=, 62
      end
    end
  end

  def test_persistent_partial_header_write_retains_physical_bytes_and_closes_descriptor
    source = track(XitDB.memory)
    source.transaction { |root| root["n"] = 7 }
    [false, true].each do |existing|
      target_path = path("persistent-#{existing}")
      File.binwrite(target_path, "") if existing
      captured = retained = original_error = nil
      failure = Errno::ENOSPC.new("persistent conversion header failure")
      configure = lambda do |store|
        captured = store
        file = store.instance_variable_get(:@file)
        sync = store.method(:sync)
        count = 0
        store.define_singleton_method(:sync) do
          count += 1
          if count == 4
            write = file.method(:pwrite)
            first = true
            file.define_singleton_method(:pwrite) do |bytes, offset|
              if first
                first = false
                write.call(bytes.byteslice(0, 3), offset)
              else
                raise failure
              end
            end
          end
          sync.call
        end
        lock = store.method(:with_exclusive_lock)
        store.define_singleton_method(:with_exclusive_lock) do |**options, &block|
          lock.call(**options, &block)
        rescue XitDB::CommitError => error
          original_error = error
          retained = File.binread(target_path)
          raise
        end
      end
      with_target_store(target_path, configure) do
        error = assert_raises(XitDB::CommitError) { source.convert(to: target_path, profile: :portable) }
        assert_same original_error, error
        assert_same failure, error.cause
        assert_equal :unknown, error.outcome
      end
      assert captured.closed?
      assert captured.instance_variable_get(:@file).closed?
      assert_equal retained, File.binread(target_path)
    end
  end

  def test_initialization_and_failed_copy_cleanup_preserve_competing_writes
    source = track(XitDB.memory)
    source.transaction { |root| root["n"] = 1 }
    target_path = path("initial-race")
    configure = lambda do |store|
      lock = store.method(:with_exclusive_lock)
      store.define_singleton_method(:with_exclusive_lock) do |**options, &block|
        File.binwrite(target_path, "competing writer")
        lock.call(**options, &block)
      end
    end
    with_target_store(target_path, configure) do
      assert_raises(ArgumentError) { source.convert(to: target_path, profile: :portable) }
    end
    assert_equal "competing writer", File.binread(target_path)
    target_path = path("cleanup-race")
    failure = RuntimeError.new("callback failed")
    configure = lambda do |store|
      lock = store.method(:with_exclusive_lock)
      count = 0
      store.define_singleton_method(:with_exclusive_lock) do |**options, &block|
        count += 1
        if count == 3
          XitDB.open(target_path) { |other| other.transaction { |root| root["competitor"] = 99 } }
        end
        lock.call(**options, &block)
      end
    end
    with_target_store(target_path, configure) do
      assert_same failure, assert_raises(RuntimeError) {
        source.convert(to: target_path, profile: :portable, transform: ->(**) { raise failure })
      }
    end
    XitDB.open(target_path) { |other| assert_equal 99, other.snapshot["competitor"] }
  end

  def test_copy_stream_conflicts_and_nonlocal_exit_leave_destination_unchanged
    source = track(XitDB.memory)
    source.transaction { |root| root["n"] = 1 }
    destination = track(XitDB.memory)
    destination.transaction do |root|
      root["bytes"] = "old"
      calls = 0
      root.open_bytes("bytes") do |_reader|
        assert_raises(XitDB::ConcurrentModificationError) do
          root.context.copy_from(source.snapshot, at: ["bytes"], transform: ->(value:, **) { calls += 1; value })
        end
      end
      assert_equal 0, calls
      result = catch(:cancel) do
        root.context.copy_from(source.snapshot, at: ["copy"], transform: ->(**) { throw :cancel, :cancelled })
      end
      assert_equal :cancelled, result
      assert_equal({"bytes" => "old"}, root.to_ruby)
    end
    result = catch(:cancel) do
      source.convert(to: path("nonlocal"), profile: :portable, transform: ->(**) { throw :cancel, :cancelled })
    end
    assert_equal :cancelled, result
    assert_equal 0, File.size(path("nonlocal"))
  end

  def test_copy_validates_destination_keys_and_root_kind_before_callbacks
    source = track(XitDB.memory)
    source.transaction { |root| root["list"] = [1] }
    destination = track(XitDB::Ruby.memory)
    key = +"bad"
    def key.special = true
    calls = 0
    transform = ->(value:, **) { calls += 1; value }
    destination.transaction do |root|
      assert_raises(XitDB::UnsupportedValueError) { root.context.copy_from(source.snapshot, at: [key], transform: transform) }
      assert_raises(XitDB::UnsupportedValueError) do
        root.context.copy_from(source.snapshot, at: [Class.new(String).new("bad")], transform: transform)
      end
      assert_raises(XitDB::ProfileMismatchError) { root.context.copy_from(source.snapshot["list"], at: [], transform: transform) }
      assert_equal 0, calls
      assert_empty root
    end
  end

  def test_native_codec_registry_is_copied_and_callbacks_remain_value_local
    type = Struct.new(:amount)
    calls = []
    codec = XitDB::Ruby::Codec.new(id: "example/value/v1", type: type,
      dump: ->(value) { calls << :dump; value.amount.to_s },
      load: ->(bytes) { calls << :load; type.new(Integer(bytes)) })
    source = track(XitDB::Ruby.memory(codecs: [codec]))
    source.transaction { |root| root["value"] = type.new(42); root["plain"] = 1 }
    calls.clear
    target = track(source.convert(to: path("codec"), profile: :ruby))
    assert_equal [:load, :dump], calls
    refute_same source.profile.codecs, target.profile.codecs
    refute_same source.profile.instance_variable_get(:@registry), target.profile.instance_variable_get(:@registry)
    assert_same codec, target.profile.codecs.first
    assert_equal 42, target.snapshot["value"].amount
    configured = XitDB::Profiles::Ruby.new
    assert_raises(XitDB::UnsupportedValueError) { source.convert(to: path("no-codec"), profile: configured) }
  end

  def test_untagged_native_binary_streams_remain_streamable
    source = track(XitDB::Ruby.memory)
    source.transaction { |root| root.write_bytes(:binary) { |io| io.write("\x00\xff".b * 50_000) } }
    enforce_bounded_reads(source.core)
    target = track(source.convert(to: path("native-binary"), profile: :ruby))
    target.snapshot.open_bytes(:binary) do |io|
      assert_equal 100_000, io.size
      assert_equal "\x00\xff".b * 50_000, io.read
    end
  end

  def test_streamed_native_strings_reject_malformed_wire_fields
    fixtures = [
      ["\x02".b, XitDB::UnsupportedEncodingError],
      ["\x01\x01\x85\x00UTF-8\x00".b, XitDB::InvalidValueError],
      ["\x01\x01\x05UTF-8\x02x".b, XitDB::InvalidValueError],
      ["\x01\x01\x05UTF-8\x00x".b, XitDB::InvalidValueError],
      ["\x01\x01\x03bad\x00".b, XitDB::UnsupportedEncodingError]
    ]
    fixtures.each_with_index do |(payload, error), index|
      source = track(XitDB::Ruby.memory)
      source.transaction { |root| root["bad"] = XitDB::Core::ByteValue.new(payload, format_tag: "rb") }
      assert_raises(error) { source.convert(to: path("invalid-string-#{index}"), profile: :portable) }
      assert_equal 0, File.size(path("invalid-string-#{index}"))
    end
  end

  def test_stored_cycles_abort_conversion_with_the_source_path
    source = track(XitDB.memory)
    source.core.transaction do |history|
      transaction = history.transaction
      block = transaction.append("\0".b * 144)
      header = transaction.append([1, block].pack("Q>Q>"))
      cycle = XitDB::Core::Slot.new(tag: :array_list, value: header)
      transaction.write_at(block, cycle.to_bytes)
      map = XitDB::Core::HashMap.new(transaction.cursor(slot: XitDB::Core::Slot.new))
      map.put(Digest::SHA1.digest("cycle"), key: source.core.bytes("cycle"), value: cycle)
      XitDB::Core::ArrayList.new(history).append(map.cursor.slot)
    end
    error = assert_raises(XitDB::CyclicValueError) { source.convert(to: path("cycle"), profile: :ruby) }
    assert_equal ["cycle", 0], error.path
    assert_equal 0, File.size(path("cycle"))
  end

  def test_deep_graph_and_shared_histories_copy_incrementally
    source = track(XitDB.memory)
    nested = "leaf"
    600.times { nested = [nested] }
    source.transaction do |root|
      root["deep"] = nested
      root["shared"] = (0...64).to_a
    end
    24.times do |index|
      source.transaction do |root|
        root.delete("deep") if index.zero?
        root["revision"] = index
      end
    end
    target = track(source.convert(to: path("deep-histories"), profile: :ruby))
    assert_equal 25, target.history.size
    assert_nil target.history[0]["revision"]
    assert_equal 23, target.snapshot["revision"]
    assert_equal 63, target.history[12]["shared"][63]
    value = target.history[0]["deep"].to_ruby
    600.times { value = value[0] }
    assert_equal "leaf", value
  end

  private

  def track(database)
    @handles << database
    database
  end

  def enforce_bounded_reads(core)
    core.define_singleton_method(:read_at) do |offset, size, bound:|
      raise "conversion allocated a complete byte value" if size > 65_536

      super(offset, size, bound: bound)
    end
  end

  def with_target_store(target, configure)
    original = XitDB::Core::FileStore.method(:open)
    XitDB::Core::FileStore.singleton_class.remove_method(:open)
    XitDB::Core::FileStore.define_singleton_method(:open) do |pathname, **options|
      store = original.call(pathname, **options)
      if pathname == target
        configure.call(store)
        configure = ->(_) {}
      end
      store
    end
    yield
  ensure
    XitDB::Core::FileStore.singleton_class.remove_method(:open)
    XitDB::Core::FileStore.define_singleton_method(:open, original)
  end

  def path(name)
    File.join(@directory, "#{name}.xit")
  end
end
