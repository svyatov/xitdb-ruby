# frozen_string_literal: true

require "test_helper"
require "xitdb/ruby"

# Retained snapshot views should read their leaf, independent of ancestor depth.
# @api private
class PublicSnapshotReferenceTest < Minitest::Test
  # Reads of a captured leaf have the same storage cost at shallow and deep paths.
  def test_retained_snapshot_reads_do_not_repeat_ancestor_traversal
    [XitDB, XitDB::Ruby].each do |factory|
      factory.memory do |database|
        data = [1, 2, 3]
        40.times { data = { "child" => data } }
        database.transaction do |root|
          root["shallow"] = [1, 2, 3]
          root["deep"] = data
        end
        snapshot = database.snapshot
        shallow = snapshot["shallow"]
        deep = snapshot["deep"]
        40.times { deep = deep["child"] }

        shallow_reads = storage_reads(database) { assert_equal [1, 2, 3], shallow.to_ruby }
        deep_reads = storage_reads(database) { assert_equal [1, 2, 3], deep.to_ruby }

        assert_operator deep_reads, :<=, shallow_reads + 2, "#{factory}: #{shallow_reads} shallow, #{deep_reads} deep"
      end
    end
  end

  # Snapshot references stay fixed while transaction views follow edits and expire.
  def test_retained_references_preserve_snapshot_and_transaction_lifetimes
    [XitDB, XitDB::Ruby].each do |factory|
      factory.memory do |database|
        database.transaction { |root| root["items"] = [{ "value" => 1 }] }
        snapshot = database.snapshot
        old_items = snapshot["items"]
        old_row = old_items[0]
        old_slice = old_items[0, 1]
        live = nil

        assert_raises(RuntimeError) do
          database.transaction do |root|
            live = root["items"][0]
            root["items"][0]["value"] = 2

            assert_equal 2, live["value"]
            assert_equal 1, old_row["value"]
            raise "rollback"
          end
        end
        assert_raises(XitDB::ExpiredViewError) { live.to_ruby }
        assert_equal 1, database.snapshot["items"][0]["value"]

        database.transaction do |root|
          live = root["items"][0]
          root["copy"] = old_row
          root["items"][0]["value"] = 3

          assert_equal 3, live["value"]
          assert_equal 1, root["copy"]["value"]
          root["items"].insert(0, { "value" => 0 })
          assert_raises(XitDB::ExpiredViewError) { live.to_ruby }
        end
        assert_equal [{ "value" => 1 }], old_items.to_ruby
        assert_equal [{ "value" => 1 }], old_slice.to_ruby
        assert_equal({ "value" => 1 }, old_row.to_ruby)
        database.close
        assert_raises(XitDB::ClosedError) { old_row.to_ruby }
        assert_raises(XitDB::ClosedError) { old_items.size }
        assert_raises(XitDB::ClosedError) { old_slice.to_ruby }
      end
    end
  end

  private

  # Count real Core reads while leaving storage and returned data unchanged.
  def storage_reads(database, &)
    count = 0
    trace = TracePoint.new(:call) do |event|
      count += 1 if event.method_id == :read_at && event.self.equal?(database.core)
    end
    trace.enable(&)
    count
  ensure
    trace&.disable
  end
end
