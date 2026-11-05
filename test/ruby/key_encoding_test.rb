# frozen_string_literal: true

# Regression tests for canonical Ruby key bytes and rejection of unsupported key behavior.

require_relative "test_helper"
require "open3"
require "rbconfig"

# Covers canonical Ruby key bytes and rejection of unsupported key behavior.
# @api private
class RubyKeyEncodingTest < RubyProfileTest
  # Checks distinct types and equal encoded strings.
  def test_distinct_types_and_equal_encoded_strings
    assert_equal "03000101", key_bytes(1).unpack1("H*")
    refute_equal key_bytes(1), key_bytes(1.0)
    assert_equal key_bytes(""), key_bytes("".encode("UTF-16BE"))
    assert_equal key_bytes("name"), key_bytes("name".b)
    refute_equal key_bytes("é"), key_bytes("é".b)
  end

  # Checks key encoding against fixed canonical byte vectors.
  def test_literal_canonical_vectors
    {
      nil => "00", false => "01", true => "02", 0 => "030000", -1 => "03010101",
      "name" => "0500046e616d65", :name => "0600046e616d65",
      "é" => "05055554462d3802c3a9", "é".b => "050a41534349492d3842495402c3a9",
      1.0 => "043ff0000000000000", -0.0 => "040000000000000000",
      Float::INFINITY => "047ff0000000000000", -Float::INFINITY => "04fff0000000000000",
      2**64 => "030009010000000000000000"
    }.each do |value, hex|
      bytes = key_bytes(value)

      assert_equal hex, bytes.unpack1("H*")
      assert_predicate bytes, :frozen?
      assert_equal Encoding::BINARY, bytes.encoding
    end
  end

  # Checks canonical keys for empty strings in every encoding and compatible ASCII strings.
  def test_all_empty_encodings_and_ascii_compatible_strings
    Encoding.list.each do |encoding|
      assert_equal "050000", key_bytes("".dup.force_encoding(encoding)).unpack1("H*"), encoding.name
      next unless encoding.ascii_compatible?

      assert_equal "0500046e616d65", key_bytes("name".dup.force_encoding(encoding)).unpack1("H*"), encoding.name
    end
    assert_equal "05085554462d31364245020061", key_bytes("a".encode("UTF-16BE")).unpack1("H*")
    assert_equal "05055554462d3801ff", key_bytes("\xff".dup.force_encoding("UTF-8")).unpack1("H*")
    assert_equal key_bytes(0.0), key_bytes(-0.0)
  end

  # Checks rejected key types and singleton behavior.
  def test_rejected_key_types_and_singleton_behavior
    [Float::NAN, [], {}, Time.at(0), Rational(1, 2), Object.new, proc {}].each do |value|
      assert_raises(XitDB::UnsupportedValueError) { key_bytes(value) }
    end
    value = +"name"
    # Adds singleton behavior that value or key validation must reject.
    def value.special = :singleton_behavior
    assert_raises(XitDB::UnsupportedValueError) { key_bytes(value) }
  end

  # Checks that fresh processes produce literal canonical bytes.
  def test_fresh_processes_produce_literal_canonical_bytes
    script = <<~RUBY
      require "xitdb/ruby/key_encoding"
      encoded = [nil, false, true, 1, "name", :name, -0.0, 2**64].map do |v|
        XitDB::Ruby::KeyEncoding.dump(v).unpack1("H*")
      end
      puts encoded
    RUBY
    expected = "00\n01\n02\n03000101\n0500046e616d65\n0600046e616d65\n040000000000000000\n030009010000000000000000\n"
    2.times do
      output, errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)

      assert_predicate status, :success?, errors
      assert_equal "", errors
      assert_equal expected, output
    end
  end

  # Checks rejects all singleton behavior without calling input reflection.
  def test_rejects_all_singleton_behavior_without_calling_input_reflection
    singleton_inputs.each do |value|
      assert_raises(XitDB::UnsupportedValueError) { key_bytes(value) }
    end
  end

  # Checks rejects basic object without object methods.
  def test_rejects_basic_object_without_object_methods
    assert_raises(XitDB::UnsupportedValueError) { key_bytes(BasicObject.new) }
  end

  # Checks rejects extensions without calling their identity hooks.
  def test_rejects_extensions_without_calling_their_identity_hooks
    each_identity_hook_input do |value, calls, behavior|
      assert_raises(XitDB::UnsupportedValueError, behavior.to_s) { key_bytes(value) }
      assert_empty calls
      assert_equal "text", value
    end
    assert_equal "05000474657874", key_bytes("text").unpack1("H*")
  end

  # Checks rejects removed encoding unrelated and private inherited methods.
  def test_rejects_removed_encoding_unrelated_and_private_inherited_methods
    %i[bytesize upcase display puts initialize_copy is_a?].each do |method|
      value = +"text"
      value.singleton_class.undef_method(method)
      assert_raises(XitDB::UnsupportedValueError, method.to_s) { key_bytes(value) }
      value.freeze
      assert_raises(XitDB::UnsupportedValueError, "frozen #{method}") { key_bytes(value) }
    end
  end
end
