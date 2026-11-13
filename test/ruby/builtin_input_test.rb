# frozen_string_literal: true

require "test_helper"
require "xitdb/ruby"

class RubyBuiltinInputTest < Minitest::Test
  def test_builtin_contents_ignore_overrides_in_small_and_paged_inputs
    [1, 32, 1025].each do |count|
      calls = []
      text = hostile(+"value", %i[class is_a? bytesize encoding b dup initialize_copy to_str], calls)
      row = hostile({ "name" => text, "number" => 7 }, %i[class is_a? size keys each_pair default default_proc], calls)
      rows = hostile(Array.new(count, row), %i[class is_a? size slice each each_with_index []], calls)
      expected = Array.new(count) { { "name" => "value", "number" => 7 } }
      XitDB::Ruby.memory do |database|
        database.transaction { |root| root["rows"] = rows }

        assert_equal expected, database.snapshot["rows"].to_ruby
        assert_empty calls
        assert_equal "value", String.instance_method(:to_s).bind_call(text)
      end
    end
  end

  def test_string_keys_ignore_hooks_through_lookup_and_retained_views
    calls = []
    key = hostile(+"key", %i[class is_a? bytesize encoding b dup initialize_copy to_str hash eql?], calls).freeze
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        root[key] = { "value" => 1 }
        retained = root[key]
        retained["value"] = 2

        assert_equal({ "value" => 2 }, retained.to_ruby)
      end
      assert_equal({ "key" => { "value" => 2 } }, database.snapshot.to_ruby)
      assert_equal({ "value" => 2 }, database.snapshot[key].to_ruby)
      assert_empty calls
    end
  end

  def test_undefined_and_private_string_methods_do_not_change_stored_contents
    text = +"\xff".b
    text.singleton_class.undef_method(:bytesize)
    text.singleton_class.class_eval do
      private

      def encoding = raise("private encoding hook ran")
      def initialize_copy(*) = raise("copy hook ran")
    end
    XitDB::Ruby.memory do |database|
      database.transaction { |root| root["value"] = text }
      result = database.snapshot["value"]

      assert_equal [255], result.bytes
      assert_equal Encoding::BINARY, result.encoding
    end
  end

  def test_cycles_and_unsupported_defaults_still_rollback
    calls = []
    cyclic = []
    cyclic << cyclic
    hostile(cyclic, %i[each each_with_index], calls)
    invalid = hostile(Hash.new(1), %i[default default_proc compare_by_identity?], calls)
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        root["kept"] = 1
        assert_raises(XitDB::CyclicValueError) { root["bad"] = cyclic }
        assert_raises(XitDB::UnsupportedValueError) { root["bad"] = invalid }
        assert_equal({ "kept" => 1 }, root.to_ruby)
      end
      assert_empty calls
    end
  end

  def test_page_fallback_keeps_nested_contents_without_running_hooks
    calls = []
    child = hostile([1, 2], %i[each each_with_index], calls)
    row = hostile({ "nested" => child }, %i[each_pair keys size], calls)
    rows = hostile(Array.new(32, row), %i[each each_with_index slice size], calls)
    XitDB::Ruby.memory do |database|
      database.transaction { |root| root["rows"] = rows }

      assert_equal Array.new(32) { { "nested" => [1, 2] } }, database.snapshot["rows"].to_ruby
      assert_empty calls
    end
  end

  def test_stream_and_copy_keys_are_owned_without_copy_hooks
    calls = []
    key = hostile(+"key", %i[dup initialize_copy to_str is_a?], calls)
    XitDB.memory do |source|
      source.transaction { |root| root["value"] = 1 }
      XitDB::Ruby.memory do |database|
        database.transaction do |root|
          root.write_bytes(key) { |writer| writer.write("bytes") }

          root.open_bytes(key) { |reader| assert_equal "bytes", reader.read }
          root.context.copy_from(source.snapshot, at: [key])

          assert_equal({ "value" => 1 }, root[key].to_ruby)
        end
        key.replace("changed")

        assert_equal({ "key" => { "value" => 1 } }, database.snapshot.to_ruby)
        assert_empty calls
      end
    end
  end

  def test_error_paths_do_not_call_string_key_inspect
    calls = []
    key = hostile(+"key", %i[inspect], calls).freeze
    cycle = []
    cycle << cycle
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        unsupported = assert_raises(XitDB::UnsupportedValueError) { root[key] = Object.new }
        cyclic = assert_raises(XitDB::CyclicValueError) { root[key] = cycle }
        missing = assert_raises(KeyError) { root.fetch(key) }
        nested = assert_raises(XitDB::UnsupportedValueError) { root["outer"] = { key => Object.new } }

        assert_equal ["key"], unsupported.path
        assert_equal ["key", 0], cyclic.path
        assert_equal %w[outer key], nested.path
        assert_includes missing.message, "key"
        assert_empty root
        assert_empty calls
      end
    end
  end

  def test_extended_scalars_still_reject_private_method_overrides
    calls = []
    altered = Time.at(0)
    altered.singleton_class.class_eval do
      private

      define_method(:puts) do |*|
        calls << :puts
        raise "private hook ran"
      end
    end
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        root["kept"] = Time.at(1)

        assert_raises(XitDB::UnsupportedValueError) { root["bad"] = altered }
        assert_equal({ "kept" => Time.at(1) }, root.to_ruby)
        assert_empty calls
      end
    end
  end

  private

  def hostile(value, names, calls)
    names.each do |name|
      value.define_singleton_method(name) do |*|
        calls << name
        raise "input hook #{name} ran"
      end
    end
    value
  end
end
