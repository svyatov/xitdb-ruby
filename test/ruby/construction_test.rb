# frozen_string_literal: true

require "ruby/test_helper"
require "xitdb/ruby"

class RubyConstructionTest < Minitest::Test
  def test_record_construction_limits_unreachable_storage
    records = Array.new(58) do |index|
      { "name" => "method_#{index}", "namespace" => "Example", "path" => "lib/example.rb",
        "complexity" => index, "coverage" => nil, "crap" => nil }
    end
    Dir.mktmpdir do |dir|
      path = File.join(dir, "data.xit")
      XitDB::Ruby.open(path) do |database|
        first = database.transaction { |root| root["data"] = records }
        initial_size = File.size(path)
        database.transaction { |root| root["data"][17]["complexity"] = -1 }

        assert_equal records, first["data"].to_ruby
        assert_equal(-1, database.snapshot["data"][17]["complexity"])
        assert_equal records.first.keys, database.snapshot["data"][0].to_ruby.keys
        database.compact(to: File.join(dir, "compact.xit")).close

        assert_operator initial_size, :<, File.size(File.join(dir, "compact.xit")) * 1.9
      end
    end
  end
end
