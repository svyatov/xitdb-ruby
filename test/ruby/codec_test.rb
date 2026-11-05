# frozen_string_literal: true

require_relative "test_helper"
require "xitdb/ruby"
require "tmpdir"

class RubyCodecTest < Minitest::Test
  Money = Struct.new(:amount)

  def money_codec(dump: lambda(&:amount), load: ->(bytes) { Money.new(bytes.dup) })
    XitDB::Ruby::Codec.new(id: "example/money/v1", type: Money, dump: dump, load: load)
  end

  def test_unknown_codec_preserves_bytes_without_loading_classes
    Dir.mktmpdir do |directory|
      path = File.join(directory, "codec.xit")
      XitDB::Ruby.open(path, codecs: [money_codec]) do |db|
        db.transaction { |root| root[:price] = Money.new("\x00\xff".b) }
      end
      original_bytes = "\x01\x0a\x10example/money/v1\x02\x00\xff".b
      XitDB::Ruby.open(path) do |db|
        unknown = db.snapshot[:price]

        assert_instance_of XitDB::Ruby::EncodedValue, unknown
        assert_equal "example/money/v1", unknown.codec_id
        assert_equal original_bytes, unknown.bytes
        assert_predicate unknown, :frozen?
        assert_predicate unknown.bytes, :frozen?
        db.transaction { |root| root[:copy] = unknown }
      end
      loads = []
      codec = money_codec(load: lambda { |bytes|
        loads << bytes
        Money.new(bytes.dup)
      })
      XitDB::Ruby.open(path, codecs: [codec]) do |db|
        assert_empty loads
        assert_equal 2, db.snapshot.size
        assert_empty loads
        assert_equal "\x00\xff".b, db.snapshot[:copy].amount
        assert_equal 1, loads.size
      end
    end
  end

  def test_failed_dump_restores_root_allocations_and_views
    calls = 0
    failure = RuntimeError.new("dump failed")
    codec = money_codec(dump: lambda { |_value|
      calls += 1
      raise failure
    })
    XitDB::Ruby.memory(codecs: [codec]) do |db|
      db.transaction do |root|
        root[:kept] = [1]
        child = root[:kept]
        previous_root = root.context.root
        bound = root.context.read_bound
        error = assert_raises(XitDB::CodecError) { root[:bad] = ["allocated" * 20, Money.new("1")] }
        assert_same failure, error.cause
        assert_equal 1, calls
        assert_equal previous_root, root.context.root
        assert_equal bound, root.context.read_bound
        assert_equal [1], child.to_ruby
        child << 2
      end

      assert_equal({ kept: [1, 2] }, db.snapshot.to_ruby)
    end
  end

  def test_key_enumeration_never_loads_values
    loads = 0
    codec = money_codec(load: lambda { |_|
      loads += 1
      raise "unrequested loader"
    })
    [XitDB.map, XitDB.sorted_map(key: :string)].each do |declaration|
      XitDB::Ruby.memory(codecs: [codec]) do |db|
        db.transaction do |root|
          root[:items] = declaration
          root[:items]["price"] = Money.new("100")

          assert_equal ["price"], root[:items].keys
          assert_equal ["price"], root[:items].each_key.to_a
        end
        assert_equal ["price"], db.snapshot[:items].keys
        assert_equal ["price"], db.snapshot[:items].each_key.to_a
        assert_equal 0, loads
      end
    end
  end

  def test_dig_traverses_native_maps_arrays_and_captured_slices
    captured = nil
    codec = money_codec(load: ->(_) { captured })
    XitDB::Ruby.memory(codecs: [codec]) do |db|
      db.transaction do |root|
        root[:items] = XitDB.linked_array
        root[:items].push({ name: ["first"] }, { name: ["last"] })
        captured = root[:items][1, 1]
        root[:slice] = Money.new("reference")

        assert_equal "first", root.dig(:items, 0, :name, 0)
        assert_equal "last", root.dig(:slice, 0, :name, 0)
        assert_raises(XitDB::ReadOnlyError) { root.dig(:slice, 0, :name) << "changed" }
        root[:items][1][:name][0] = "changed"

        assert_equal "last", root.dig(:slice, 0, :name, 0)
      end
      assert_equal "changed", db.snapshot.dig(:items, -1, :name, 0)
      assert_raises(XitDB::ExpiredViewError) { db.snapshot.dig(:slice, 0) }
    end
  end

  def test_registry_rejects_duplicates_and_builtin_overrides_before_filesystem_effects
    codec = money_codec
    builtin_types = [NilClass, FalseClass, TrueClass, Integer, Float, String, Symbol, Time,
                     Date, DateTime, BigDecimal, Rational, Hash, Array, Set,
                     XitDB::Core::ByteValue, XitDB::Ruby::EncodedValue, XitDB::CollectionDeclaration]
    registrations = [[codec, codec], [codec, money_codec],
                     [codec, XitDB::Ruby::Codec.new(id: "example/other/v1", type: Money,
                                                    dump: ->(v) { v }, load: ->(v) { v })]]
    builtin_types.each do |type|
      registrations << [XitDB::Ruby::Codec.new(id: "example/builtin/v1", type: type,
                                               dump: ->(v) { v }, load: ->(v) { v })]
    end
    Dir.mktmpdir do |directory|
      path = File.join(directory, "rejected.xit")
      registrations.each do |codecs|
        assert_raises(XitDB::CodecConfigurationError) { XitDB::Ruby.open(path, codecs: codecs) }
        refute_path_exists path
      end
    end
  end

  def test_invalid_basic_object_codec_arguments_raise_configuration_errors
    callback = ->(value) { value }
    invalid = BasicObject.new

    [{ type: invalid, dump: callback, load: callback },
     { type: Money, dump: invalid, load: callback },
     { type: Money, dump: callback, load: invalid }].each do |options|
      assert_raises(XitDB::CodecConfigurationError) do
        XitDB::Ruby::Codec.new(id: "example/invalid/v1", **options)
      end
    end
  end

  def test_codec_configuration_does_not_call_type_predicate_hooks
    callback = ->(_value) { "bytes" }
    def callback.is_a?(*) = raise("callback type hook ran")
    type = Class.new
    def type.is_a?(*) = raise("class type hook ran")

    codec = XitDB::Ruby::Codec.new(id: "example/predicate/v1", type: type, dump: callback, load: callback)

    assert_equal "bytes", codec.dump(type.new)
    assert_equal "bytes", codec.load("bytes")
  end

  def test_registry_captures_inputs_and_dispatches_exact_classes
    codec = money_codec
    inputs = [codec]
    def inputs.dup = raise("must not call dup")
    def inputs.each = raise("must not call each")
    registry = XitDB::Ruby::CodecRegistry.new(inputs)
    inputs.clear

    assert_predicate registry, :frozen?
    assert_same codec, registry.for_value(Money.new("1"))
    assert_same codec, registry.for_id("example/money/v1")
    assert_nil registry.for_value(Class.new(Money).new("1"))
    assert_nil registry.for_id("example/money/v2")
    XitDB::Ruby.memory(codecs: [codec]) do |first|
      XitDB::Ruby.memory do |second|
        first.transaction { |root| root[:value] = Money.new("1") }
        assert_raises(XitDB::UnsupportedValueError) { second.transaction { |root| root[:value] = Money.new("1") } }
      end
    end
  end

  def test_view_codecs_reject_instead_of_silently_bypassing_callbacks
    calls = []
    [XitDB::Views::Base, XitDB::Views::Map, XitDB::Views::Array, Class.new(XitDB::Views::Map)].each do |type|
      codec = XitDB::Ruby::Codec.new(id: "example/view/v1", type: type,
                                     dump: lambda { |_|
                                       calls << :dump
                                       "bytes"
                                     },
                                     load: lambda { |_|
                                       calls << :load
                                       nil
                                     })
      assert_raises(XitDB::CodecConfigurationError) { XitDB::Ruby.memory(codecs: [codec], &:close) }
    end
    assert_empty calls
  end

  def test_class_dispatch_does_not_call_class_identity_hooks
    type = Class.new(Money)
    %i[== equal? hash eql?].each do |method|
      type.define_singleton_method(method) { |*| raise "class identity hook ran" }
    end
    codec = XitDB::Ruby::Codec.new(id: "example/child/v1", type: type,
                                   dump: lambda(&:amount), load: ->(bytes) { type.new(bytes.dup) })
    XitDB::Ruby.memory(codecs: [money_codec, codec]) do |db|
      db.transaction do |root|
        root[:parent] = Money.new("1")
        root[:child] = type.new("2")
      end

      assert_equal "1", db.snapshot[:parent].amount
      assert_equal "2", db.snapshot[:child].amount
    end
  end

  def test_basic_object_only_registrations_reject_before_file_creation
    calls = []
    Dir.mktmpdir do |directory|
      path = File.join(directory, "unreachable.xit")
      [BasicObject, Class.new(BasicObject)].each do |type|
        type.define_singleton_method(:<=) { |*| raise "class ancestry hook ran" }
        codec = XitDB::Ruby::Codec.new(id: "example/basic/v1", type: type,
                                       dump: lambda { |_|
                                         calls << :dump
                                         "bytes"
                                       },
                                       load: lambda { |_|
                                         calls << :load
                                         nil
                                       })
        assert_raises(XitDB::CodecConfigurationError) { XitDB::Ruby.open(path, codecs: [codec], &:close) }
        refute_path_exists path
      ensure
        type.singleton_class.remove_method(:<=)
      end
    end

    assert_empty calls
  end

  def test_invalid_codec_definitions_reject_without_calling_input_hooks
    [nil, "", "\xff".b, BasicObject.new].each do |id|
      assert_raises(XitDB::CodecConfigurationError) do
        XitDB::Ruby::Codec.new(id: id, type: Money, dump: ->(v) { v }, load: ->(v) { v })
      end
    end
    [nil, Money.new, Module.new].each do |type|
      assert_raises(XitDB::CodecConfigurationError) do
        XitDB::Ruby::Codec.new(id: "example/v1", type: type, dump: ->(v) { v }, load: ->(v) { v })
      end
    end
    hostile = Object.new
    def hostile.respond_to_missing?(*) = raise("reflection hook ran")
    assert_raises(XitDB::CodecConfigurationError) { money_codec(dump: hostile) }
    assert_raises(XitDB::CodecConfigurationError) { money_codec(load: nil) }
    id = +"example/money/v1"
    codec = XitDB::Ruby::Codec.new(id: id, type: Money, dump: lambda(&:amount), load: ->(v) { Money.new(v) })
    id.replace("changed")

    assert_equal "example/money/v1", codec.id
    assert_predicate codec, :frozen?
    assert_predicate codec.id, :frozen?
  end

  def test_invalid_dump_output_and_nonlocal_exit_restore_assignment
    callback = nil
    codec = money_codec(dump: ->(value) { callback.call(value) })
    XitDB::Ruby.memory(codecs: [codec]) do |db|
      db.transaction do |root|
        root[:kept] = 1
        before = root.context.root
        bound = root.context.read_bound
        callback = ->(_value) { 100 }
        assert_raises(XitDB::CodecError) { root[:price] = Money.new("1") }
        callback = ->(_value) { throw :stop, :stopped }

        assert_equal :stopped, catch(:stop) { root[:price] = ["temporary" * 20, Money.new("1")] }
        assert_equal before, root.context.root
        assert_equal bound, root.context.read_bound
        callback = ->(value) { value.amount.freeze }
        root[:price] = Money.new("100")

        assert_equal "100", root[:price].amount
      end
    end
  end

  def test_load_is_not_called_for_other_identifiers_or_invalid_envelopes
    calls = 0
    codec = money_codec(load: lambda { |bytes|
      calls += 1
      Money.new(bytes)
    })
    XitDB::Ruby.memory(codecs: [codec]) do |db|
      db.transaction do |root|
        root[:unknown] = XitDB.bytes("\x01\x0a\x10example/money/v2\x01x".b, format_tag: "rb")
        root[:invalid] = XitDB.bytes("\x01\x0a\x10example/money/v1\x01x\x00".b, format_tag: "rb")
      end

      assert_instance_of XitDB::Ruby::EncodedValue, db.snapshot[:unknown]
      assert_raises(XitDB::InvalidValueError) { db.snapshot[:invalid] }
      assert_equal 0, calls
    end
  end

  def test_scalar_freezing_does_not_call_custom_freeze_methods
    type = Class.new do
      def freeze = raise("must use trusted freeze")
    end
    codec = XitDB::Ruby::Codec.new(id: "example/value/v1", type: type, dump: ->(_) { "bytes" }, load: lambda { |_|
      type.new
    })
    XitDB::Ruby.memory(codecs: [codec]) do |db|
      db.transaction { |root| root[:value] = type.new }

      assert_predicate db.snapshot[:value], :frozen?
      refute_predicate db.snapshot.to_ruby[:value], :frozen?
    end
  end

  def test_registered_scalar_and_container_subclasses_use_codecs_only_for_values
    [String, Time, Date, Array, Hash, Set].each do |base|
      type = Class.new(base)
      value = if base == Time
                type.at(0)
              else
                (base == Date ? type.jd(0) : type.new)
              end
      calls = 0
      codec = XitDB::Ruby::Codec.new(id: "example/subclass/v1", type: type,
                                     dump: lambda { |_input|
                                       calls += 1
                                       "payload"
                                     }, load: ->(_bytes) { type.allocate })
      XitDB::Ruby.memory(codecs: [codec]) do |db|
        db.transaction do |root|
          root[:value] = value

          assert_instance_of type, root[:value]
          assert_equal 1, calls
          assert_raises(XitDB::UnsupportedValueError) { root[value] = 2 }
          assert_raises(XitDB::UnsupportedValueError) { root[:set] = Set[value] }
          assert_equal 1, calls
        end
      end
    end
  end

  def test_load_receives_frozen_independent_bytes_and_materializes_fresh_values
    payloads = []
    codec = money_codec(load: lambda { |bytes|
      payloads << bytes
      Money.new(bytes.dup)
    })
    XitDB::Ruby.memory(codecs: [codec]) do |db|
      original = Money.new(+"100")
      db.transaction { |root| root[:price] = original }
      original.amount.replace("changed")
      first = db.snapshot[:price]
      second = db.snapshot[:price]

      assert_predicate first, :frozen?
      refute_same first, second
      assert_equal "100", first.amount
      refute_same payloads[0], payloads[1]
      assert payloads.all?(&:frozen?)
      materialized = db.snapshot.to_ruby[:price]

      refute_predicate materialized, :frozen?
      materialized.amount.replace("200")

      assert_equal "100", db.snapshot[:price].amount
      refute_predicate original, :frozen?
    end
  end

  def test_dump_callback_rejects_nested_writes_across_contexts_and_allows_reads
    callback = nil
    calls = 0
    codec = money_codec(dump: lambda { |value|
      calls += 1
      callback.call
      value.amount
    })
    XitDB::Ruby.memory(codecs: [codec]) do |db|
      db.transaction do |root|
        root[:detached] = { value: 1 }
        detached = root.delete(:detached)
        callback = -> { detached[:bad] = [2] }
        assert_raises(XitDB::TransactionStateError) { root[:bad] = Money.new("1") }
        assert_equal({ value: 1 }, detached.to_ruby)
        refute root.key?(:bad)
        callback = lambda {
          assert_equal 1, detached[:value]
          assert_raises(XitDB::TransactionStateError) { root[:sibling] = 2 }
        }
        root[:price] = Money.new("3")

        assert_equal 2, calls
        assert_equal "3", root[:price].amount
        detached[:value] = 4
      end
    end
  end

  def test_delete_loaders_run_once_inside_the_mutation_guard
    expected_amounts = { delete: ["1"], delete_at: ["2"], pop: ["3"], pop_many: %w[2 3] }
    %i[delete delete_at pop pop_many].each do |operation|
      callback = nil
      calls = 0
      codec = money_codec(load: lambda { |bytes|
        calls += 1
        callback&.call
        Money.new(bytes.dup)
      })
      XitDB::Ruby.memory(codecs: [codec]) do |db|
        db.transaction do |root|
          root[:value] = Money.new("1")
          root[:items] = [[0], Money.new("2"), Money.new("3")]
          root[:detached] = { kept: 4 }
          detached = root.delete(:detached)
          items = root[:items]
          child = items[0]
          remove = case operation
                   when :delete then -> { root.delete(:value) }
                   when :delete_at then -> { items.delete_at(1) }
                   when :pop then -> { items.pop }
                   else -> { items.pop(2) }
                   end
          before = root.context.root
          bound = root.context.read_bound
          callback = -> { detached[:bad] = [5] }

          assert_raises(XitDB::TransactionStateError, operation.to_s, &remove)
          assert_equal 1, calls
          assert_equal before, root.context.root
          assert_equal bound, root.context.read_bound
          assert_equal({ kept: 4 }, detached.to_ruby)
          assert_equal [0], child.to_ruby
          callback = lambda {
            assert_equal 4, detached[:kept]
            assert_raises(XitDB::TransactionStateError) { root[:sibling] = 6 }
          }
          removed = remove.call

          assert_equal(operation == :pop_many ? 3 : 2, calls)
          expected = expected_amounts.fetch(operation)

          assert_equal expected, (operation == :pop_many ? removed : [removed]).map(&:amount)
          child << 1
          detached[:kept] = 7
          root[:later] = true
        end
      end
    end
  end

  def test_multi_pop_partial_loader_failure_preserves_views_and_iteration
    calls = 0
    failure = RuntimeError.new("load failed")
    codec = money_codec(load: lambda { |bytes|
      calls += 1
      raise failure if calls == 2

      Money.new(bytes.dup)
    })
    XitDB::Ruby.memory(codecs: [codec]) do |db|
      db.transaction do |root|
        root[:items] = [[0], Money.new("1"), Money.new("2")]
        items = root[:items]
        child = items[0]
        iterator = items.each

        assert_equal [0], iterator.next.to_ruby
        before = root.context.root
        bound = root.context.read_bound
        error = assert_raises(XitDB::CodecError) { items.pop(2) }
        assert_same failure, error.cause
        assert_equal 2, calls
        assert_equal before, root.context.root
        assert_equal bound, root.context.read_bound
        assert_equal "1", iterator.next.amount
        child << 3

        assert_equal %w[1 2], items.pop(2).map(&:amount)
        assert_equal [[0, 3]], items.to_ruby
      end
    end
  end

  def test_delete_loader_failures_and_stream_conflicts_preserve_state
    %i[delete delete_at pop].each do |operation|
      fail_load = true
      calls = 0
      codec = money_codec(load: lambda { |bytes|
        calls += 1
        raise "loader failed" if fail_load

        Money.new(bytes.dup)
      })
      XitDB::Ruby.memory(codecs: [codec]) do |db|
        db.transaction do |root|
          root[:value] = Money.new("1")
          root[:items] = [Money.new("2")]
          items = root[:items]
          remove = { delete: -> { root.delete(:value) }, delete_at: -> { items.delete_at(0) }, pop: lambda {
            items.pop
          } }.fetch(operation)
          before = root.context.root
          bound = root.context.read_bound

          assert_raises(XitDB::CodecError, &remove)
          assert_equal 1, calls
          assert_equal before, root.context.root
          assert_equal bound, root.context.read_bound
          target, key = operation == :delete ? [root, :value] : [items, 0]
          target.write_bytes(key) do |writer|
            assert_raises(XitDB::ConcurrentModificationError, &remove)
            assert_equal 1, calls
            writer.write("replacement")
          end
          fail_load = false
          target[key] = Money.new("3")

          assert_equal "3", remove.call.amount
          root[:later] = true
        end
      end
    end
  end
end
