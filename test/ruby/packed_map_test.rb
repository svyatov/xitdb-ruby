# frozen_string_literal: true

require "test_helper"
require "xitdb/ruby"
require "tmpdir"

class RubyPackedMapTest < Minitest::Test
  def test_small_records_reduce_retained_storage_and_preserve_snapshots
    records = Array.new(58) do |index|
      { "name" => "method_#{index}", "namespace" => "Example", "path" => "lib/example.rb",
        "complexity" => index, "coverage" => nil, "crap" => nil }
    end
    %w[memory file].each do |store|
      Dir.mktmpdir do |dir|
        database = store == "memory" ? XitDB::Ruby.memory : XitDB::Ruby.open(File.join(dir, "source"))
        database.transaction { |root| root["data"] = records }
        before = database.snapshot
        database.transaction { |root| root["data"][27]["complexity"] = 123 }

        assert_equal records, before["data"].to_ruby
        assert_equal 123, database.snapshot["data"][27]["complexity"]
        assert_equal records.first.keys, database.snapshot["data"][0].to_ruby.keys
        compacted = database.compact(to: File.join(dir, "compact"))

        assert_operator File.size(File.join(dir, "compact")), :<, 30_000
      ensure
        compacted&.close
        database&.close
      end
    end
  end

  def test_promotion_and_reinsertion_preserve_map_and_set_order
    XitDB::Ruby.memory do |database|
      original = (0...16).to_h { |index| ["field_#{index}", index] }
      database.transaction do |root|
        root["map"] = original
        root["set"] = Set.new(0...16)
      end
      before = database.snapshot
      database.transaction do |root|
        map = root["map"]
        map["field_0"] = -1
        map["field_16"] = 16
        map.delete("field_3")
        map["field_3"] = 33
        members = root["set"]
        members.add(16)
        members.delete(3)
        members.add(3)
      end

      assert_equal original, before["map"].to_ruby
      assert_equal (0...16).to_a, before["set"].to_a
      assert_equal original.keys.reject { |key| key == "field_3" } + %w[field_16 field_3],
                   database.snapshot["map"].to_ruby.keys
      assert_equal((0..16).to_a.reject { |value| value == 3 } + [3], database.snapshot["set"].to_a)
      assert_equal 33, database.snapshot["map"]["field_3"]
    end
  end

  def test_oversized_keys_do_not_force_unrelated_payload_reads
    XitDB::Ruby.memory do |database|
      database.transaction { |root| root["map"] = { "x" * (8 * 1024 * 1024) => 1, "safe" => 2 } }
      core = database.core
      original = core.method(:read_at)
      maximum = 0
      core.define_singleton_method(:read_at) do |offset, length, **options|
        maximum = [maximum, length].max
        original.call(offset, length, **options)
      end

      assert_equal 2, database.snapshot["map"]["safe"]
      assert_operator maximum, :<=, 65_536
    end
  end

  def test_native_handles_use_a_distinct_profile_identifier
    XitDB::Ruby.memory do |database|
      assert_equal "rb02", database.core.header.hash_id
    end
  end

  def test_failed_record_append_rolls_back_and_allows_retry
    XitDB::Ruby.memory do |database|
      database.transaction { |root| root[:map] = { first: 1 } }
      snapshot = database.snapshot
      database.transaction do |root|
        transaction = root.context.transaction
        append = transaction.method(:append)
        fail_append = true
        transaction.define_singleton_method(:append) do |bytes|
          offset = append.call(bytes)
          raise IOError, "injected packed record failure" if fail_append

          offset
        end
        bound = transaction.length
        assert_raises(IOError) { root[:map][:second] = 2 }
        assert_equal bound, transaction.length
        assert_equal({ first: 1 }, root[:map].to_ruby)
        fail_append = false
        root[:map][:second] = 2
      end

      assert_equal({ first: 1 }, snapshot[:map].to_ruby)
      assert_equal({ first: 1, second: 2 }, database.snapshot[:map].to_ruby)
    end
  end

  def test_packed_records_reject_unknown_shapes_and_duplicate_key_identities
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        core = database.core
        profile = database.profile
        key = profile.encode_scalar("key", core: core)
        alternate = profile.encode_scalar("key".b, core: core)
        root[:invalid] = {}
        malformed = [[99, []], [1, [key]],
                     [1, [key, XitDB::Core::Slot.null, alternate, XitDB::Core::Slot.null]]]
        malformed.each do |metadata, fields|
          assert_raises(XitDB::InvalidValueError) do
            root.context.mutate([:invalid]) do |cursor|
              cursor.replace(XitDB::Core::Record.append(root.context.transaction, metadata: metadata, fields: fields))
              profile.container(cursor.slot, context: root.context, path: [:invalid])
            end
          end
          assert_empty root[:invalid]
        end
      end
    end
  end

  def test_ordinal_traversal_preserves_positions_across_promotion
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        root[:map] = { first: 1, second: 2 }
        adapter = root[:map].adapter

        assert_equal([:second], adapter.each_from_index(1).map { |key, _stored| key })
        17.times { |index| adapter.assign(index, XitDB::Core::Slot.uint(index)) }

        assert_equal([:second] + (0...17).to_a, adapter.each_from_index(1).map { |key, _stored| key })
        assert_equal([16], adapter.each_from_index(-1).map { |key, _stored| key })
      end
    end
  end
end
