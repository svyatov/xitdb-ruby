# frozen_string_literal: true

require "test_helper"
require "xitdb/ruby"

class RubyPackingStateTest < Minitest::Test
  def test_repeated_fields_share_dictionaries_and_short_values_without_ruby_aliases
    XitDB::Ruby.memory do |database|
      # Stay below the page threshold to exercise dictionary storage.
      values = Array.new(31) do |index|
        { "name" => "method_#{index}", "namespace" => "Example", "path" => "lib/example.rb",
          "complexity" => index, "coverage" => nil, "crap" => nil }
      end
      database.transaction { |root| root[:rows] = values }
      rows = database.snapshot[:rows]
      first = record(database, rows[0].slot)
      second = record(database, rows[1].slot)

      assert_equal 4, first.metadata
      assert_equal 7, first.fields.size
      assert_equal first.fields[0], second.fields[0]
      assert_equal first.fields[2], second.fields[2]
      assert_equal 5, record(database, first.fields[0]).metadata
      decoded = rows.to_ruby
      decoded[0]["namespace"].replace("changed")

      assert_equal "Example", decoded[1]["namespace"]
      assert_equal values, rows.to_ruby
      before = database.snapshot
      database.transaction { |root| root[:rows][0]["complexity"] = -1 }

      assert_equal first.fields[0], record(database, database.snapshot[:rows][0].slot).fields[0]
      assert_equal values, before[:rows].to_ruby
    end
  end

  def test_sharing_keeps_original_key_and_value_encodings
    XitDB::Ruby.memory do |database|
      values = [{ "key" => "shared", "extra" => 1 }, { "key".b => "shared".b, "extra" => 1 }]
      database.transaction { |root| root[:rows] = values }
      rows = database.snapshot[:rows]
      first = record(database, rows[0].slot)
      second = record(database, rows[1].slot)

      refute_equal first.fields[0], second.fields[0]
      refute_equal first.fields[1], second.fields[1]
      decoded = rows.to_ruby

      assert_equal Encoding::UTF_8, decoded[0].keys[0].encoding
      assert_equal Encoding::BINARY, decoded[1].keys[0].encoding
      assert_equal Encoding::UTF_8, decoded[0]["key"].encoding
      assert_equal Encoding::BINARY, decoded[1]["key"].encoding
    end
  end

  def test_operation_tables_are_bounded_and_discarded_after_failed_encoding
    state = XitDB::Ruby::PackingState.new
    400.times do |index|
      identity = state.scalar_identity("value_#{index}")
      state.store_scalar(identity, XitDB::Core::Slot.uint(index))
    end
    80.times { |index| state.schema(index.to_s) { XitDB::Core::Slot.uint(index) } }

    assert_equal 256, state.scalars.size
    assert_equal 64, state.schemas.size
    assert_nil state.scalar_identity("x" * 65)

    XitDB::Ruby.memory do |database|
      values = Array.new(80) { |index| { "field_#{index}" => "shared", "other" => index } }
      database.transaction do |root|
        before = root.context.read_bound
        assert_raises(XitDB::UnsupportedValueError) { root[:bad] = values + [Object.new] }
        assert_equal before, root.context.read_bound
        root[:good] = values
      end
      rows = database.snapshot[:good]

      assert_equal values, rows.to_ruby
      assert_equal 4, record(database, rows[0].slot).metadata
      assert_equal 1, record(database, rows[79].slot).metadata
    end
  end

  def test_equal_cached_string_contents_ignore_object_overrides
    state = XitDB::Ruby::PackingState.new
    profile = XitDB::Profiles::Ruby.new
    valid = "field"

    assert_equal profile.key_bytes(valid), profile.key_bytes(valid, state: state)
    invalid = +"field"
    invalid.define_singleton_method(:to_s) { "field" }
    invalid.freeze

    assert_equal profile.key_bytes(valid), profile.key_bytes(invalid, state: state)
    XitDB::Ruby.memory do |database|
      database.transaction do |_root|
        first = profile.encode_scalar(valid, core: database.core, state: state)

        assert_equal first, profile.encode_scalar(invalid, core: database.core, state: state)
      end
    end
  end

  def test_key_cache_inspection_does_not_call_input_hooks
    calls = []
    invalid = +"field"
    invalid.define_singleton_method(:is_a?) do |*|
      calls << :is_a?
      raise "input hook ran"
    end
    invalid.freeze
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        root[:value] = [{ invalid => 1 }]

        assert_equal [{ "field" => 1 }], root[:value].to_ruby
      end
    end

    assert_empty calls
  end

  def test_malformed_dictionaries_reject_duplicate_canonical_keys_and_shapes
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        root[:bad] = {}
        before = root.to_ruby
        first = database.profile.encode_scalar("key", core: database.core)
        alias_key = database.profile.encode_scalar("key".b, core: database.core)
        [[5, [first, alias_key]], [99, [first, first]], [5, [first]]].each do |metadata, keys|
          bound = root.context.read_bound
          assert_raises(XitDB::InvalidValueError) do
            root.context.mutate([:bad]) do |cursor|
              dictionary = XitDB::Core::Record.append(root.context.transaction, metadata: metadata, fields: keys)
              fields = [dictionary, XitDB::Core::Slot.int(1), XitDB::Core::Slot.int(2)]
              cursor.replace(XitDB::Core::Record.append(root.context.transaction, metadata: 4, fields: fields))
              database.profile.container(cursor.slot, context: root.context, path: [:bad])
            end
          end
          assert_equal bound, root.context.read_bound
          assert_equal before, root.to_ruby
        end
      end
    end
  end

  def test_a_cached_dictionary_still_checks_each_referring_maps_value_count
    XitDB::Ruby.memory do |database|
      original = [{ "first" => 1, "second" => 2 }, { "first" => 3, "second" => 4 }]
      database.transaction { |root| root[:rows] = original }
      before = database.snapshot
      dictionary = record(database, before[:rows][0].slot).fields[0]

      assert_equal dictionary, record(database, before[:rows][1].slot).fields[0]
      database.transaction do |root|
        root.context.mutate([:rows, 1]) do |cursor|
          fields = [dictionary, XitDB::Core::Slot.int(3), XitDB::Core::Slot.int(4), XitDB::Core::Slot.int(5)]
          cursor.replace(XitDB::Core::Record.append(root.context.transaction, metadata: 4, fields: fields))
        end
      end

      assert_raises(XitDB::InvalidValueError) { database.snapshot[:rows].to_ruby }
      assert_equal original.first, database.snapshot[:rows][0].to_ruby
      assert_equal original, before[:rows].to_ruby
    end
  end

  private

  def record(database, slot)
    XitDB::Core::Record.read(database.core, slot, bound: database.core.committed_size)
  end
end
