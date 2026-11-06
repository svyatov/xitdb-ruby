# frozen_string_literal: true

# Checks renamed validation contracts and boolean queries.
require "test_helper"

# Covers clean API renames without changing validation or cursor invalidation.
class CoreNamingTest < Minitest::Test
  Core = XitDB::Core

  # Checks integer validation returns its input and preserves rejection details.
  def test_integer_validation_returns_input_or_raises
    assert_equal 3, Core::Format.integer!(3, 0..5)
    error = assert_raises(TypeError) { Core::Format.integer!("3", 0..5) }
    assert_equal "expected Integer, got String", error.message
    error = assert_raises(RangeError) { Core::Format.integer!(6, 0..5) }
    assert_equal "integer outside 0..5", error.message
    refute_respond_to Core::Format, :integer
  end

  # Checks width assertions preserve valid returns and distinct type and corruption errors.
  def test_width_assertion_preserves_error_contract
    assert_nil Core::Format.ensure_width!("abc", 3)
    error = assert_raises(TypeError) { Core::Format.ensure_width!(nil, 3) }
    assert_equal "expected String, got NilClass", error.message
    error = assert_raises(XitDB::CorruptionError) { Core::Format.ensure_width!("ab", 3) }
    assert_equal "expected 3 bytes, got 2", error.message
    refute_respond_to Core::Format, :width
  end

  # Checks the full predicate returns exact booleans without changing slot bytes.
  def test_full_predicate_preserves_slot_encoding
    assert_same false, Core::Slot.new.full?
    assert_same true, Core::Slot.null.full?
    assert_equal "800000000000000000", Core::Slot.null.to_bytes.unpack1("H*")
    refute_respond_to Core::Slot.null, :full
  end

  # Checks the protected validity predicate tracks child invalidation.
  def test_validity_predicate_preserves_visibility_and_invalidation
    database = Core::Database.memory

    assert Core::Cursor.protected_method_defined?(:valid?)
    refute Core::Cursor.protected_method_defined?(:valid)
    database.transaction do |root|
      list = Core::ArrayList.new(root)
      list.append(Core::Slot.uint(1))
      child = list.cursor_at(0)

      assert_same true, child.send(:valid?)
      root.invalidate_children(index: 0)

      assert_same false, child.send(:valid?)
      assert_raises(XitDB::ExpiredViewError) { child.slot }
    end
  ensure
    database&.close
  end
end
