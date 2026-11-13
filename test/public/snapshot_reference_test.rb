# frozen_string_literal: true

require "test_helper"
require "xitdb/ruby"

# Retained snapshot views should read their leaf, independent of ancestor depth.
# @api private
class PublicSnapshotReferenceTest < Minitest::Test
  # Freezing a live view does not prevent it from following later mutations.
  def test_frozen_transaction_views_follow_updates
    [XitDB, XitDB::Ruby].each do |factory|
      factory.memory do |database|
        database.transaction do |root|
          root["items"] = [{ "value" => 1 }]
          items = root["items"].freeze
          row = items[0].freeze
          slice = items[0, 1].freeze
          root.freeze
          root["items"][0]["value"] = 2

          assert_equal 2, row["value"]
          assert_equal [{ "value" => 2 }], items.to_ruby
          assert_equal [{ "value" => 1 }], slice.to_ruby
          assert_equal 2, root["items"][0]["value"]
        end
      end
    end
  end

  # Stable transaction views read their own storage without retracing ancestors.
  def test_retained_transaction_reads_do_not_repeat_ancestor_traversal
    [XitDB, XitDB::Ruby].each do |factory|
      factory.memory do |database|
        data = [1, 2, 3]
        40.times { data = { "child" => data } }
        database.transaction do |root|
          root["shallow"] = [1, 2, 3]
          root["deep"] = data
          shallow = root["shallow"]
          deep = root["deep"]
          40.times { deep = deep["child"] }

          2.times do |iteration|
            root["unrelated"] = iteration

            assert_equal [1, 2, 3], shallow.to_ruby
            assert_equal [1, 2, 3], deep.to_ruby
            shallow_reads = storage_reads(database) { assert_equal [1, 2, 3], shallow.to_ruby }
            deep_reads = storage_reads(database) { assert_equal [1, 2, 3], deep.to_ruby }

            assert_operator deep_reads, :<=, shallow_reads + 2,
                            "#{factory}: #{shallow_reads} shallow, #{deep_reads} deep"
          end
        end
      end
    end
  end

  # Location notification needs no stored keys when every observed view is shallower.
  def test_unobserved_location_notification_does_not_read_storage
    [XitDB, XitDB::Ruby].each do |factory|
      factory.memory do |database|
        database.transaction do |root|
          root["items"] = [{ "value" => 1 }]
          items = root["items"]
          row = items[0]
          reads = storage_reads(database) { root.context.replace_location(["items", 0, "value"]) }

          assert_equal 0, reads
          assert_equal 1, row["value"]
          root.context.replace_location(["items", 0])
          assert_raises(XitDB::ExpiredViewError) { row.to_ruby }
          assert_equal 1, items.size
        end
      end
    end
  end

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
