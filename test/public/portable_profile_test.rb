# frozen_string_literal: true

# Regression tests for portable scalar encoding, strict keys, and exact integer boundaries.

require "test_helper"

# Covers portable scalar encoding, strict keys, and exact integer boundaries.
# @api private
class PortableProfileTest < Minitest::Test
  Core = XitDB::Core

  # Creates a raw memory database for portable scalar allocations.
  def setup
    @core = Core::Database.memory
  end

  # Closes the raw scalar fixture database.
  def teardown
    @core.close
  end

  # Returns the portable profile used by the scalar fixtures.
  # @return [XitDB::Profiles::Portable] cached profile
  def profile
    @profile ||= XitDB::Profiles::Portable.new
  end

  # Encodes one portable scalar using the test memory database.
  # @param value [Object] Ruby scalar
  # @return [XitDB::Core::Slot] encoded slot
  def encode(value)
    profile.encode_scalar(value, core: @core)
  end

  # Checks portable scalar boundaries and rejection of keys outside the portable string contract.
  def test_portable_types_and_strict_keys
    assert_raises(XitDB::UnsupportedValueError) { profile.key_bytes(:name) }
    assert_equal "name".b, profile.key_bytes("name")
    assert_equal :uint, encode((2**64) - 1).tag
    assert_raises(RangeError) { encode(2**64) }
  end

  # Checks signed and unsigned payloads decode exactly.
  def test_signed_and_unsigned_payloads_decode_exactly
    [[-(2**63), :int, 0x8000000000000000], [-1, :int, 0xffffffffffffffff],
     [0, :int, 0], [(2**63) - 1, :int, 0x7fffffffffffffff],
     [2**63, :uint, 0x8000000000000000], [(2**64) - 1, :uint, 0xffffffffffffffff]].each do |value, tag, bits|
      slot = encode(value)

      assert_equal tag, slot.tag
      assert_equal bits, slot.value
      assert_equal value, profile.decode_scalar(slot, core: @core)
    end
    assert_raises(RangeError) { encode(-(2**63) - 1) }
    assert_equal :uint, encode(XitDB.uint(1)).tag
    assert_equal 1, profile.decode_scalar(encode(XitDB.uint(1)), core: @core)
    assert_predicate XitDB.uint(0), :frozen?
    assert_raises(RangeError) { XitDB.uint(-1) }
    assert_raises(RangeError) { XitDB.uint(2**64) }
    assert_raises(TypeError) { XitDB.uint(1.0) }
  end

  # Checks that nil occupies a slot and unsupported scalars raise.
  def test_nil_occupies_a_slot_and_unsupported_scalars_raise
    assert encode(nil).full
    assert_nil profile.decode_scalar(encode(nil), core: @core)
    [true, false, :name, Object.new, {}, []].each do |value|
      assert_raises(XitDB::UnsupportedValueError) { encode(value) }
      assert_raises(XitDB::UnsupportedValueError) { profile.key_bytes(value) }
    end
  end

  # Checks float payloads preserve bits.
  def test_float_payloads_preserve_bits
    [[1.5, 0x3ff8000000000000], [-0.0, 0x8000000000000000],
     [Float::INFINITY, 0x7ff0000000000000], [-Float::INFINITY, 0xfff0000000000000]].each do |value, bits|
      slot = encode(value)

      assert_equal :float, slot.tag
      assert_equal bits, slot.value
      assert_equal bits, [profile.decode_scalar(slot, core: @core)].pack("G").unpack1("Q>")
    end
    assert_predicate profile.decode_scalar(encode(Float::NAN), core: @core), :nan?
  end

  # Checks string bytes determine read encoding.
  def test_string_bytes_determine_read_encoding
    [["hello", Encoding::UTF_8], ["\xc3\xa9".b, Encoding::UTF_8], ["\xff".b, Encoding::BINARY],
     ["\xc3".b, Encoding::BINARY], ["\0abcdefgh".b, Encoding::UTF_8], ["", Encoding::UTF_8]].each do |input, encoding|
      @core.transaction { |root| root.replace(encode(input)) }
      value = profile.decode_scalar(@core.root_cursor.slot, core: @core)

      assert_equal input.b, value.b
      assert_equal encoding, value.encoding
      assert_predicate value, :frozen?
      assert_raises(FrozenError) { value << "x" }
      mutable = profile.decode_scalar(@core.root_cursor.slot, core: @core, immutable: false)
      mutable << "x"

      assert_equal input.b, profile.decode_scalar(@core.root_cursor.slot, core: @core).b
    end
    latin1 = "\xe9".b.force_encoding("ISO-8859-1")

    assert_equal "\xe9".b, profile.key_bytes(latin1)
    source = +"key"
    key = profile.key_bytes(source)
    source.replace("changed")

    assert_equal "key".b, key
    assert_equal Encoding::BINARY, key.encoding
  end

  # Checks tagged bytes are opaque immutable values.
  def test_tagged_bytes_are_opaque_immutable_values
    data = +"\0opaque bytes"
    tag = +"\xff\0".b
    declaration = XitDB.bytes(data, format_tag: tag)
    data.clear
    tag.clear
    @core.transaction { |root| root.replace(encode(declaration)) }
    decoded = profile.decode_scalar(@core.root_cursor.slot, core: @core, immutable: false)

    assert_equal "\0opaque bytes".b, decoded.bytes
    assert_equal "\xff\0".b, decoded.format_tag
    assert_predicate decoded, :frozen?
    assert_raises(FrozenError) { decoded.bytes.clear }
    assert_raises(FrozenError) { decoded.format_tag.clear }
    assert_raises(ArgumentError) { XitDB.bytes("data", format_tag: "bad") }
    assert_raises(TypeError) { XitDB.bytes(1) }
    assert_raises(XitDB::UnsupportedValueError) { profile.key_bytes(declaration) }
  end

  # Checks decode uses the supplied snapshot bound.
  def test_decode_uses_the_supplied_snapshot_bound
    old = @core.root_cursor
    @core.transaction { |root| root.replace(encode("longer than eight bytes")) }
    assert_raises(XitDB::CorruptionError) do
      profile.decode_scalar(@core.root_cursor.slot, core: @core, bound: old.bound)
    end
    assert_raises(XitDB::UnsupportedValueError) do
      profile.decode_scalar(Core::Slot.new(tag: :array_list), core: @core)
    end
  end

  # Checks all collection declarations capture immutable metadata.
  def test_all_collection_declarations_capture_immutable_metadata
    declarations = [[XitDB.map, :hash_map, false], [XitDB.map(counted: true), :counted_hash_map, true],
                    [XitDB.set, :hash_set, false], [XitDB.set(counted: true), :counted_hash_set, true],
                    [XitDB.array, :array_list, false], [XitDB.linked_array, :linked_array_list, false],
                    [XitDB.sorted_map, :sorted_map, false], [XitDB.sorted_set, :sorted_set, false]]
    declarations.each do |declaration, kind, counted|
      assert_equal kind, declaration.kind
      assert_equal counted, declaration.counted?
      assert_predicate declaration, :frozen?
      assert_raises(XitDB::UnsupportedValueError) { encode(declaration) }
    end
    assert_raises(ArgumentError) { XitDB.map(counted: 1) }
    assert_raises(ArgumentError) { XitDB.set(counted: nil) }
  end

  # Checks builtin hashers match independent vectors.
  def test_builtin_hashers_match_independent_vectors
    [[Core::Hasher.sha1, "sha1", 20, "a9993e364706816aba3e25717850c26c9cd0d89d"],
     [Core::Hasher.sha256, "sha2", 32, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"],
     [Core::Hasher.sha384, "sha2", 48,
      "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"],
     [Core::Hasher.sha512, "sha2", 64,
      "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a219" \
      "2992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"]].each do |hasher, id, width, hex|
      assert_equal id.b, hasher.id
      assert_equal width, hasher.size
      assert_equal hex, hasher.digest("abc").unpack1("H*")
      assert_predicate hasher, :frozen?
    end
    assert_equal "sha1".b, profile.hasher.id
    custom = Core::Hasher.sha256

    assert_same custom, XitDB::Profiles::Portable.new(hasher: custom).hasher
    assert_raises(TypeError) { XitDB::Profiles::Portable.new(hasher: :sha1) }
  end

  # Checks custom hashers validate identifiers and digest widths.
  def test_custom_hashers_validate_identifiers_and_digest_widths
    id = +"test"
    result = +"12"
    hasher = Core::Hasher.new(id: id, size: 2) { |bytes| bytes == "abc".b ? result : "x" }
    id.clear

    assert_equal "test".b, hasher.id
    digest = hasher.digest("abc")
    result.clear

    assert_equal "12".b, digest
    assert_equal Encoding::BINARY, digest.encoding
    assert_predicate digest, :frozen?
    assert_raises(FrozenError) { hasher.id.clear }
    assert_raises(ArgumentError) { hasher.digest("different") }
    assert_raises(TypeError) { hasher.digest(1) }
    assert_raises(TypeError) { Core::Hasher.new(id: 1, size: 2) { nil } }
    assert_raises(ArgumentError) { Core::Hasher.new(id: "short", size: 2) { nil } }
    [0, -1, 65_536].each { |size| assert_raises(RangeError) { Core::Hasher.new(id: "test", size: size) { nil } } }
    assert_raises(TypeError) { Core::Hasher.new(id: "test", size: 1.0) { nil } }
    assert_raises(ArgumentError) { Core::Hasher.new(id: "test", size: 2) }
    assert_raises(TypeError) { Core::Hasher.new(id: "test", size: 2) { 12 }.digest("abc") }
  end
end
