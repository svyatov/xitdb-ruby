# frozen_string_literal: true

require "test_helper"
require "xitdb/ruby"

class RubyEncodingValidationTest < Minitest::Test
  Trigger = Struct.new(:value)

  class ObservedProfile < XitDB::Profiles::Ruby
    attr_reader :observed

    def initialize
      @observed = []
      super
    end

    def encode_scalar(value, core:, **options)
      @observed << value
      super
    end
  end

  def test_bulk_encoding_keeps_scalar_dispatch_owned_by_the_profile
    profile = ObservedProfile.new
    database = XitDB::Database.new(core: XitDB::Core::Database.memory(hash_id: "rb03", hash_size: 32), profile: profile)
    database.transaction { |root| root[:rows] = [{ "field" => "value", "number" => 1 }] }

    assert_equal [{ "field" => "value", "number" => 1 }], database.snapshot[:rows].to_ruby
    assert_includes profile.observed, "value"
    assert_includes profile.observed, "field"
    assert_includes profile.observed, 1
  ensure
    database&.close
  end

  def test_a_codec_cannot_make_a_later_string_reuse_stale_cached_contents
    later = +"shared"
    codec = XitDB::Ruby::Codec.new(id: "validation/trigger", type: Trigger,
                                   dump: lambda { |_value|
                                     later.replace("changed")
                                     later.define_singleton_method(:hidden) { raise "private hook ran" }
                                     later.singleton_class.send(:private, :hidden)
                                     "payload"
                                   }, load: ->(bytes) { Trigger.new(bytes) })
    XitDB::Ruby.memory(codecs: [codec]) do |database|
      database.transaction do |root|
        root[:kept] = [1]
        root[:values] = [later, Trigger.new, later]

        assert_equal ["shared", Trigger.new("payload"), "changed"], root[:values].to_ruby
        assert_equal [1], root[:kept].to_ruby
        root[:good] = "shared"

        assert_equal "shared", root[:good]
      end
    end
  end
end
