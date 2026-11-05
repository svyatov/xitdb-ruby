# frozen_string_literal: true

require_relative "test_helper"

class RubyWireTest < RubyProfileTest
  Wire = XitDB::Ruby::Wire

  def test_literal_wire_fields
    { u: [[0, "00"], [127, "7f"], [128, "8001"], [624_485, "e58e26"]],
      b: [["\x00\xff".b, "0200ff"], ["", "00"]],
      t: [%w[é 02c3a9], ["a".encode("UTF-16BE"), "0161"]],
      z: [[0, "0000"], [256, "00020100"], [-256, "01020100"]],
      q: [[Rational(-3, 2), "01010302"], [Rational(0), "000001"]],
      f64: [[1.0, "3ff0000000000000"], [-0.0, "8000000000000000"]] }.each do |method, vectors|
      vectors.each do |value, hex|
        assert_equal hex, Wire.public_send(method, value).unpack1("H*")
        reader = Wire::Reader.new([hex].pack("H*"))
        expected = method == :t ? value.encode("UTF-8") : value

        assert_equal expected, reader.public_send(method)
        reader.finish!
      end
    end
  end

  def test_malformed_fields
    { u: ["", "80", "8000", "8100"], b: %w[02ff ffffffffffffffffff01],
      t: %w[01ff 02c080], z: %w[02 0100 000100 00020001 0002ff],
      q: %w[00010001 00010100 00010204 000002], f64: ["00000000000000"] }.each do |method, vectors|
      vectors.each do |hex|
        assert_raises(XitDB::InvalidValueError, "#{method}: #{hex}") do
          Wire::Reader.new([hex].pack("H*")).public_send(method)
        end
      end
    end
    assert_raises(XitDB::InvalidValueError) { Wire::Reader.new("x").finish! }
    assert_raises(XitDB::InvalidValueError) { Wire.u(-1) }
    assert_raises(XitDB::InvalidValueError) { Wire.t("\xff".dup.force_encoding("UTF-8")) }
  end
end
