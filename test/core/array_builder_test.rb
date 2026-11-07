# frozen_string_literal: true

require "test_helper"

class ArrayBuilderTest < Minitest::Test
  Core = XitDB::Core

  def test_bounded_construction_matches_indexed_lists_at_tree_boundaries
    [0, 1, 15, 16, 17, 255, 256, 257, 4095, 4096, 4097, 10_000].each do |count|
      database = Core::Database.memory
      begin
        database.transaction do |root|
          builder = Core::ArrayBuilder.new(root.transaction)
          count.times { |index| builder.append(Core::Slot.uint(index)) }
          stored = builder.slot
          bound = root.transaction.length

          assert_equal stored, builder.slot
          assert_equal bound, root.transaction.length
          root.replace(stored)
          list = Core::ArrayList.new(root)

          assert_equal count, list.size
          assert_equal (0...count).to_a, list.map(&:value)
          assert_equal count - 1, list.get(-1).value if count.positive?
          assert_raises(XitDB::TransactionStateError) { builder.append(Core::Slot.null) }
        end
      ensure
        database.close
      end
    end
  end

  def test_invalid_elements_and_ended_writers_cannot_extend_the_builder
    database = Core::Database.memory
    builder = nil
    database.transaction do |root|
      builder = Core::ArrayBuilder.new(root.transaction)
      before = root.transaction.length

      assert_raises(TypeError) { builder.append(nil) }
      assert_raises(XitDB::CorruptionError) { builder.append(Core::Slot.new(tag: 127)) }
      assert_raises(XitDB::InvalidValueError) { builder.append(Core::Slot.new(tag: :index)) }
      assert_equal before, root.transaction.length
    end

    assert_raises(XitDB::ExpiredViewError) { builder.append(Core::Slot.null) }
    assert_raises(XitDB::ExpiredViewError) { builder.slot }
  ensure
    database&.close
  end
end
