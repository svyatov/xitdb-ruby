# frozen_string_literal: true

# Regression tests for selector handling without trusting caller-defined type checks.

require "test_helper"

# Covers selector handling without trusting caller-defined type checks.
# @api private
class SelectorProtocolTest < Minitest::Test
  # Provides a string selector whose type hook raises if library validation calls it.
  # @api private
  class Key < String
    # Makes an object hook observable to detect use of caller-defined behavior.
    def is_a?(*)
      raise "selector type hooks must not run"
    end
  end

  # Checks stream assignment uses native selector type checks.
  def test_stream_assignment_uses_native_selector_type_checks
    XitDB.memory do |database|
      database.transaction do |root|
        root.write_bytes(Key.new("blob")) { |writer| writer.write("ok") }
      end

      assert_equal "ok", database.snapshot["blob"]
    end
  end

  # Checks copy path uses native selector type checks.
  def test_copy_path_uses_native_selector_type_checks
    XitDB.memory do |source|
      source.transaction { |root| root["x"] = 1 }
      XitDB.memory do |database|
        database.transaction do |root|
          root.context.copy_from(source.snapshot, at: [Key.new("copy")])
        end

        assert_equal({ "x" => 1 }, database.snapshot["copy"].to_ruby)
      end
    end
  end

  # Checks transformed keys use native selector type checks.
  def test_transformed_keys_use_native_selector_type_checks
    XitDB.memory do |source|
      source.transaction { |root| root["x"] = 1 }
      XitDB.memory do |database|
        database.transaction do |root|
          root.context.copy_from(source.snapshot, at: ["copy"], transform: lambda { |value:, role:, **|
            role == :key ? Key.new(value) : value
          })
        end

        assert_equal({ "x" => 1 }, database.snapshot["copy"].to_ruby)
      end
    end
  end
end
