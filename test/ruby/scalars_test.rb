# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"

class RubyScalarsTest < RubyProfileTest
  Scalars = XitDB::Ruby::Scalars

  def test_literal_scalar_fixtures
    values = {
      "nil" => nil, "false" => false, "true" => true, "zero" => 0,
      "signed_min" => -(2**63), "signed_max" => 2**63 - 1,
      "unsigned_min" => 2**63, "unsigned_max" => 2**64 - 1,
      "large_positive" => 2**64, "large_negative" => -(2**63) - 1,
      "positive_zero" => 0.0, "negative_zero" => -0.0,
      "positive_infinity" => Float::INFINITY, "negative_infinity" => -Float::INFINITY,
      "utf8" => "é", "binary" => "é".b, "invalid_utf8" => "\xff".dup.force_encoding("UTF-8"),
      "empty" => "", "symbol" => :name
    }
    fixtures = JSON.parse(File.read(File.expand_path("../fixtures/ruby/v1/scalars.json", __dir__)))
    fixtures.fetch("values").each do |fixture|
      next if fixture.fetch("name") == "custom"

      value = values.fetch(fixture.fetch("name"))
      slot = store(value)
      bytes = fixture.key?("slot") ? slot.to_bytes : @core.read_bytes(slot).bytes
      assert_equal fixture["slot"] || fixture["payload"], bytes.unpack1("H*"), fixture.fetch("name")
      decoded = Scalars.decode(slot, core: @core)
      value.nil? ? assert_nil(decoded) : assert_equal(value, decoded)
      assert decoded.frozen?
      if value.is_a?(String)
        assert_equal value.encoding, decoded.encoding
        assert_equal value.bytes, decoded.bytes
      end
    end
  end

  def test_all_empty_encoding_identities_and_string_ownership
    Encoding.list.each do |encoding|
      value = "".dup.force_encoding(encoding)
      decoded = round_trip(value)
      assert_equal encoding, decoded.encoding
      assert_empty decoded
    end
    original = +"value"
    slot = store(original)
    original.replace("changed")
    first = Scalars.decode(slot, core: @core, immutable: false)
    second = Scalars.decode(slot, core: @core, immutable: false)
    refute first.frozen?
    first.replace("different")
    assert_equal "value", second
    assert_equal "value", Scalars.decode(slot, core: @core)
    assert_equal :é, round_trip(:é)
    assert_equal "é".b.to_sym, round_trip("é".b.to_sym)
  end

  def test_huge_integers_and_float_bit_patterns
    [-(2**4096), 2**4096].each { |value| assert_equal value, round_trip(value) }
    %w[0000000000000000 8000000000000000 7ff8000000000001 fff8000000000042 7ff0000000000001].each do |hex|
      value = [hex].pack("H*").unpack1("G")
      assert_equal hex, [round_trip(value)].pack("G").unpack1("H*")
    end
  end

  def test_binary_tagged_and_unknown_custom_payloads
    assert_equal Encoding::BINARY, decode_payload("6162", format_tag: nil).encoding
    assert decode_payload("", format_tag: nil).frozen?
    refute decode_payload("6162", format_tag: nil, immutable: false).frozen?
    opaque = decode_payload("00ff01", format_tag: "xy")
    assert_instance_of XitDB::Core::ByteValue, opaque
    assert_equal "xy", opaque.format_tag
    assert_equal "00ff01", opaque.bytes.unpack1("H*")
    custom = decode_payload("010a0461636d650300ff01")
    assert_instance_of XitDB::Ruby::EncodedValue, custom
    assert_equal "acme", custom.codec_id
    assert_equal "rb", custom.format_tag
    assert_equal "010a0461636d650300ff01", custom.bytes.unpack1("H*")
    assert custom.frozen?
    assert custom.codec_id.frozen?
    assert custom.bytes.frozen?
    assert_equal custom.bytes, @core.read_bytes(store(custom)).bytes
    assert_equal opaque.bytes, @core.read_bytes(store(opaque)).bytes
  end

  def test_unknown_versions_types_and_encodings
    %w[02 0100 01ff].each do |hex|
      assert_raises(XitDB::UnsupportedEncodingError) { decode_payload(hex) }
    end
    assert_raises(XitDB::UnsupportedEncodingError) { decode_payload("01010362616400") }
    assert_raises(XitDB::UnsupportedEncodingError) { decode_payload("01020362616400") }
  end

  def test_malformed_payload_boundaries
    %w[01 0103 010302 01030100 0101055554462d3802ff 0101ff 010101ff00
       01040100 0104000100 010400020001 010a0461636d65 010a0461636d6502ff
       010a0461636d650000 0102055554462d3801ff].each do |hex|
      assert_raises(XitDB::InvalidValueError, hex) { decode_payload(hex) }
    end
    assert_raises(XitDB::InvalidValueError) { decode_payload("") }
    assert_raises(XitDB::InvalidValueError) { Scalars.decode(XitDB::Core::Slot.new(tag: :array_list), core: @core) }
  end

  def test_truncation_and_captured_core_bound
    hex = "0101055554462d3802c3a9"
    (0...(hex.size / 2)).each do |length|
      assert_raises(XitDB::InvalidValueError) { decode_payload(hex[0, length * 2]) }
    end
    old_bound = @core.committed_size
    slot = store("long scalar bytes")
    assert_raises(XitDB::CorruptionError) { Scalars.decode(slot, core: @core, bound: old_bound) }
  end

  def test_unsupported_inputs
    [Object.new, [], {}, proc {}, /a/].each do |value|
      assert_raises(XitDB::UnsupportedValueError) { store(value) }
    end
    value = +"text"
    def value.special = true
    assert_raises(XitDB::UnsupportedValueError) { store(value) }
  end

  def test_rejects_all_singleton_behavior_without_calling_input_reflection
    singleton_inputs.each do |value|
      assert_raises(XitDB::UnsupportedValueError) { store(value) }
    end
  end

  def test_rejects_basic_object_without_object_methods
    assert_raises(XitDB::UnsupportedValueError) { store(BasicObject.new) }
  end

  def test_rejects_extensions_without_calling_their_identity_hooks
    each_identity_hook_input do |value, calls, behavior|
      assert_raises(XitDB::UnsupportedValueError, behavior.to_s) { store(value) }
      assert_empty calls
      assert_equal "text", value
    end
    assert_equal "text", round_trip("text".freeze)
  end

  def test_rejects_removed_encoding_unrelated_and_private_inherited_methods
    %i[bytesize upcase display puts initialize_copy is_a?].each do |method|
      value = +"text"
      value.singleton_class.undef_method(method)
      assert_raises(XitDB::UnsupportedValueError, method.to_s) { store(value) }
      value.freeze
      assert_raises(XitDB::UnsupportedValueError, "frozen #{method}") { store(value) }
    end
  end

  def test_string_validation_is_nonmutating_and_warning_clean
    program = <<~'RUBY'
      require "xitdb/ruby"
      [XitDB, XitDB::Ruby].each do |profile|
        profile.memory do |db|
          db.transaction do |root|
            ["literal", "converted".to_s, String.new("owned"), "frozen".freeze].each do |value|
              root[value] = value
              raise "value changed" unless root[value] == value
              raise "caller frozen" if value != "frozen" && value.frozen?
            end
          end
        end
      end
    RUBY
    output, errors, status = Open3.capture3(RbConfig.ruby, "-w", "-Ilib", "-e", program)
    assert status.success?, errors
    assert_empty output
    assert_empty errors
  end

  def test_rejects_private_overrides_of_existing_methods_without_calling_them
    %i[initialize_copy puts].each do |name|
      [false, true].each do |prepend|
        value = +"text"
        behavior = Module.new do
          define_method(name) { |*| raise "private override ran" }
          private name
        end
        prepend ? value.singleton_class.prepend(behavior) : value.extend(behavior)
        assert_raises(XitDB::UnsupportedValueError) { store(value) }
        value.freeze
        assert_raises(XitDB::UnsupportedValueError) { store(value) }
      end
    end
  end
end
