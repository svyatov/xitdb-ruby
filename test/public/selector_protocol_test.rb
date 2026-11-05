# frozen_string_literal: true

require "test_helper"

class SelectorProtocolTest < Minitest::Test
  class Key < String
    def is_a?(*)
      raise "selector type hooks must not run"
    end
  end

  def test_stream_assignment_uses_native_selector_type_checks
    XitDB.memory do |database|
      database.transaction do |root|
        root.write_bytes(Key.new("blob")) { |writer| writer.write("ok") }
      end

      assert_equal "ok", database.snapshot["blob"]
    end
  end

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
