# frozen_string_literal: true

require "English"
require "test_helper"

class CoreLogicalMutationTest < Minitest::Test
  def setup
    @database = XitDB::Core::Database.memory
  end

  def teardown
    @database.close
  end

  def test_logical_mutation_guard_rejects_nested_entries_and_retains_outer_ownership
    @database.transaction do |cursor|
      transaction = cursor.transaction
      transaction.with_logical_mutation do
        assert_raises(XitDB::TransactionStateError) { transaction.with_logical_mutation { flunk } }
        assert_raises(XitDB::TransactionStateError) { transaction.check_logical_mutation! }
        array = XitDB::Core::ArrayList.new(cursor)
        array.append(XitDB::Core::Slot.int(1))

        assert_equal 1, array.get(0).value
      end
      transaction.with_logical_mutation { XitDB::Core::ArrayList.new(cursor).append(XitDB::Core::Slot.int(2)) }
    end

    assert_equal [1, 2], XitDB::Core::ArrayList.new(@database.root_cursor).map(&:value)
  end

  def test_logical_mutation_guard_releases_after_exceptions_and_nonlocal_exits
    @database.transaction do |cursor|
      transaction = cursor.transaction
      assert_raises(RuntimeError) { transaction.with_logical_mutation { raise "callback failed" } }
      assert_equal :thrown, catch(:stop) { transaction.with_logical_mutation { throw :stop, :thrown } }
      assert_equal(:broken, transaction.with_logical_mutation { break :broken })
      assert_equal :returned, leave_guard(transaction)
      assert_equal(:ready, transaction.with_logical_mutation { :ready })
    end
  end

  def test_logical_mutation_guard_checks_thread_ownership_and_expiry
    transaction = nil
    @database.transaction do |cursor|
      transaction = cursor.transaction
      transaction.with_logical_mutation do
        error = Thread.new do
          transaction.with_logical_mutation { flunk }
        rescue StandardError
          $ERROR_INFO
        end.value

        assert_instance_of XitDB::TransactionStateError, error
        assert_raises(XitDB::TransactionStateError) { transaction.check_logical_mutation! }
      end
    end
    assert_raises(XitDB::ExpiredViewError) { transaction.check_logical_mutation! }
    assert_raises(XitDB::ExpiredViewError) { transaction.with_logical_mutation { flunk } }
  end

  private

  def leave_guard(transaction)
    transaction.with_logical_mutation { return :returned }
  end
end
