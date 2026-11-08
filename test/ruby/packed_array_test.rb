# frozen_string_literal: true

require "test_helper"
require "xitdb/ruby"
require "tmpdir"

class RubyPackedArrayTest < Minitest::Test
  def test_arrays_cross_record_and_tree_boundaries_without_changing_snapshots
    [0, 1, 15, 16, 17, 255, 256, 257, 4095, 4096, 4097, 10_000].each do |count|
      XitDB::Ruby.memory do |database|
        original = (0...count).to_a
        database.transaction { |root| root[:array] = original }
        before = database.snapshot

        assert_equal :record, before[:array].slot.tag
        assert_equal original, before[:array].to_ruby
        database.transaction do |root|
          array = root[:array]
          array.push(:last)
          array.insert(0, :first)
          array.delete_at(1)
          array[2] = :changed
          expected = original.dup
          expected.push(:last)
          expected.insert(0, :first)
          expected.delete_at(1)
          expected[2] = :changed

          assert_equal expected, array.to_ruby
          assert_equal expected[1, 10], array[1, 10].to_ruby
          array.pop(array.size)
          array.push(:replacement)

          assert_equal [:replacement], array.to_ruby
          array.clear

          assert_empty array
        end

        assert_equal original, before[:array].to_ruby
      end
    end
  end

  def test_large_arrays_remain_selective_after_reopen_and_compaction
    Dir.mktmpdir do |directory|
      path = File.join(directory, "source")
      values = Array.new(10_000) { |index| [index, "payload"] }
      XitDB::Ruby.open(path) { |database| database.transaction { |root| root[:array] = values } }
      XitDB::Ruby.open(path) do |database|
        before = database.snapshot
        size = File.size(path)
        database.transaction { |root| root[:array][5000][0] = -1 }

        assert_operator File.size(path) - size, :<, 8192
        assert_equal 5000, before[:array][5000][0]
        assert_equal(-1, database.snapshot[:array][5000][0])
        compacted = database.compact(to: File.join(directory, "compact"))

        assert_equal(-1, compacted.snapshot[:array][5000][0])
        assert_equal [9999, "payload"], compacted.snapshot[:array][9999].to_ruby
      ensure
        compacted&.close
      end
    end
  end
end
