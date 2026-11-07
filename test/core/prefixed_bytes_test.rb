# frozen_string_literal: true

require "test_helper"
require_relative "../support/fault_store"

class PrefixedBytesTest < Minitest::Test
  def test_prefix_and_payload_are_captured_before_bounded_store_callbacks
    store = FaultStore.new(XitDB::Core::MemoryStore.new)
    core = XitDB::Core::Database.new(store: store)
    input = +("x" * 131_073)
    prefix = +"prefix"
    maximum = 0
    core.transaction do |root|
      store.fault = lambda do |name, arguments|
        next unless name == :append

        maximum = [maximum, arguments.fetch(0).bytesize].max
        input.replace("changed")
        prefix.replace("changed")
      end
      root.replace(core.bytes(input, prefix: prefix, format_tag: "xy"))
      store.fault = nil
    end

    stored = core.root_cursor.read_bytes

    assert_equal "prefix#{"x" * 131_073}", stored.bytes
    assert_equal "xy", stored.format_tag
    assert_operator maximum, :<=, 65_536
    assert_equal "changed", input
    assert_equal "changed", prefix
  ensure
    core&.close
  end
end
