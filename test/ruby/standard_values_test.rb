# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "bigdecimal"
require "json"

class RubyStandardValuesTest < RubyProfileTest
  Scalars = XitDB::Ruby::Scalars

  def test_exact_time_offset_and_decimal_zero
    time = Time.at(Rational(1, 10**12)).getlocal(3600)

    assert_equal time.to_r, round_trip(time).to_r
    assert_equal 3600, round_trip(time).utc_offset
    assert_equal BigDecimal("-0").sign, round_trip(BigDecimal("-0")).sign
  end

  def test_time_exact_instants_and_presentation
    offsets = [-86_399, 0, 86_399]
    [Rational(-1, 10**12), Rational(1, 3), 2**80].each do |instant|
      offsets.each do |offset|
        value = round_trip(Time.at(instant).getlocal(offset))

        assert_equal instant, value.to_r
        assert_equal offset, value.utc_offset
        refute_predicate value, :utc?
        assert_predicate value, :frozen?
      end
      assert_predicate round_trip(Time.at(instant).utc), :utc?
    end
  end

  def test_fractional_time_offsets_are_explicitly_unsupported
    assert_raises(XitDB::UnsupportedValueError) { store(Time.at(0).getlocal(Rational(1, 2))) }
    assert_equal 1, round_trip(Time.at(0).getlocal(Rational(1))).utc_offset
  end

  def test_decimal_decoding_preserves_application_modes
    BigDecimal.save_exception_mode do
      BigDecimal.save_limit do
        BigDecimal.mode(BigDecimal::EXCEPTION_ALL, true)
        BigDecimal.limit(2)
        mode = BigDecimal.mode(BigDecimal::EXCEPTION_ALL)

        assert_predicate decode_payload("010803"), :nan?
        assert_equal 1, decode_payload("010801").infinite?
        assert_equal [-1, "123", 10, 1], decode_payload("0108000103313233000101").split
        assert_equal mode, BigDecimal.mode(BigDecimal::EXCEPTION_ALL)
        assert_equal 2, BigDecimal.limit
      end
    end
  end

  def test_dates_preserve_calendar_start
    [Date::GREGORIAN, Date::JULIAN, Date::ITALY, Date::ENGLAND, 2_298_874, 2_426_355, 2_299_161.5].each do |start|
      [-2**70, 0, 2_299_161, 2**70].each do |jd|
        date = round_trip(Date.jd(jd, start))

        assert_instance_of Date, date
        assert_equal jd, date.jd
        assert_equal start, date.start
      end
    end
  end

  def test_datetimes_preserve_exact_instant_offset_and_calendar
    [Date::GREGORIAN, Date::JULIAN, Date::ITALY, Date::ENGLAND].each do |start|
      [Rational(-1, 1), Rational(1, 24), Rational(1, 1)].each do |offset|
        original = DateTime.jd(-123, 23, 59, Rational(59_000_000_000_001, 10**12), offset, start)
        value = round_trip(original)

        assert_instance_of DateTime, value
        assert_equal original.ajd, value.ajd
        assert_equal offset, value.offset
        assert_equal start, value.start
      end
    end
  end

  def test_decimal_normal_form_and_special_values
    %w[0 -0 1.2300 -123000 1e100000 1e-100000 Infinity -Infinity NaN].each do |text|
      original = BigDecimal(text)
      value = round_trip(original)

      assert_instance_of BigDecimal, value
      assert_equal original.split, value.split
      assert_predicate value, :frozen?
    end
    assert_equal @core.read_bytes(store(BigDecimal("1.2300"))).bytes,
                 @core.read_bytes(store(BigDecimal("1.23"))).bytes
  end

  def test_rationals_preserve_large_reduced_components
    [Rational(0), Rational(-2, 3), Rational((2**2048) + 1, 2**2048)].each do |value|
      assert_equal value, round_trip(value)
    end
  end

  def test_mutable_reads_are_independent_and_assignment_captures_time
    original = Time.at(Rational(1, 10**12)).getlocal(3600)
    slot = store(original)
    original.utc
    first = Scalars.decode(slot, core: @core, immutable: false)
    second = Scalars.decode(slot, core: @core, immutable: false)

    refute_predicate first, :frozen?
    refute_same first, second
    first.localtime(-3600)

    assert_equal 3600, second.utc_offset
    assert_equal 3600, Scalars.decode(slot, core: @core).utc_offset
    [Date.today, DateTime.now, BigDecimal("1.23"), Rational(2, 3)].each do |value|
      slot = store(value)
      first = Scalars.decode(slot, core: @core, immutable: false)
      second = Scalars.decode(slot, core: @core, immutable: false)

      refute_same first, second
      assert_equal value, first
    end
  end

  def test_standard_values_remain_unsupported_hash_keys
    [Time.at(0), Date.today, DateTime.now, BigDecimal("1"), Rational(1, 2)].each do |value|
      assert_raises(XitDB::UnsupportedValueError) { key_bytes(value) }
    end
  end

  def test_literal_standard_value_fixtures
    values = {
      "utc_epoch" => Time.at(0).utc, "fixed_epoch" => Time.at(0).getlocal(0),
      "negative_half_time" => Time.at(Rational(-1, 2)).getlocal(3600),
      "julian_day_zero" => Date.jd(0, Date::JULIAN),
      "gregorian_datetime" => DateTime.jd(0, 0, 0, 0, Rational(1, 24), Date::GREGORIAN),
      "decimal_positive_zero" => BigDecimal("0"), "decimal_negative_zero" => BigDecimal("-0"),
      "decimal_fraction" => BigDecimal("-1.2300"), "decimal_infinity" => BigDecimal("Infinity"),
      "decimal_negative_infinity" => BigDecimal("-Infinity"), "decimal_nan" => BigDecimal("NaN"),
      "rational" => Rational(-2, 3)
    }
    fixtures = JSON.parse(File.read(File.expand_path("../fixtures/ruby/v1/scalars.json", __dir__)))
    fixtures.fetch("standard_values").each do |fixture|
      original = values.fetch(fixture.fetch("name"))

      assert_equal fixture.fetch("payload"), @core.read_bytes(store(original)).bytes.unpack1("H*")
      value = decode_payload(fixture.fetch("payload"))
      original.is_a?(BigDecimal) ? assert_equal(original.split, value.split) : assert_equal(original, value)
      payload = fixture.fetch("payload")

      (0...(payload.size / 2)).each do |length|
        assert_raises(XitDB::InvalidValueError) { decode_payload(payload[0, length * 2]) }
      end
      assert_raises(XitDB::InvalidValueError) { decode_payload("#{payload}00") }
    end
  end

  def test_malformed_standard_fields
    %w[
      0105000001000002 010500000100010101 0105000001000301518000
      010600007ff8000000000000 010600000000000000000000
      010700000100010201fff0000000000000
      010700000100010180c60afff0000000000000
      010804 0108000201300000 01080000000000
      010800000230300000 010800000230310000 010800000231300000
      010800000130000101 01080000012e0000
      0108000001ff0000 0109000000 010900010202
    ].each do |hex|
      assert_raises(XitDB::InvalidValueError, hex) { decode_payload(hex) }
    end
  end
end
