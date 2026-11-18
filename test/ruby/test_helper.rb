# frozen_string_literal: true

# Shares raw Ruby-profile setup and encoding helpers across the Ruby value tests.

require_relative "../test_helper"
require "xitdb/ruby/wire"
require "xitdb/ruby/key_encoding"
require "xitdb/ruby/ordered_keys"
require "xitdb/ruby/scalars"

# Provides a raw Ruby-profile database and reusable scalar fixtures.
# @api private
class RubyProfileTest < Minitest::Test
  # Creates a raw memory database with the rb04 hash identifier and 32-byte hashes.
  def setup
    @core = XitDB::Core::Database.memory(hash_id: "rb04", hash_size: 32)
  end

  # Closes the raw Ruby-profile fixture database.
  def teardown
    @core.close
  end

  # Encodes a fixture key with the Ruby profile's canonical key format.
  # @param value [Object] supported key
  # @return [String] canonical key bytes
  def key_bytes(value)
    XitDB::Ruby::KeyEncoding.dump(value)
  end

  # Encodes a fixture key using the selected sorted-key kind.
  # @param value [Object] supported key
  # @param kind [Symbol] sorted-key kind
  # @return [String] ordered key bytes
  def ordered(value, kind)
    XitDB::Ruby::OrderedKeys.dump(value, kind: kind)
  end

  # Builds strings with singleton behavior that scalar validation must reject.
  # @return [Array<String>] adversarial fixtures
  def singleton_inputs
    values = %i[public protected private].map do |visibility|
      value = +"text"
      value.singleton_class.class_eval do
        define_method(:hidden) { true }
        send(visibility, :hidden)
      end
      value
    end
    extension = Module.new do
      private

      # Adds singleton behavior that value validation must reject.
      def hidden = :singleton_behavior
    end
    values << (+"text").extend(extension)
    values << (+"text").extend(extension).freeze
    value = +"text"
    value.singleton_class.prepend(extension)
    values << value
    value = +"text"
    class << value
      private

      # Raises if validation requests an untrusted byte size.
      def bytesize = raise("must reject before bytesize")
    end
    values << value
    value = +"text"
    # Hides singleton methods to test validation without trusting reflection hooks.
    def value.singleton_methods(*) = []
    # Raises if validation invokes this caller-defined object hook.
    def value.singleton_class = raise("must not call singleton_class")
    # Raises if validation invokes this caller-defined object hook.
    def value.class = raise("must not call class")
    # Raises if validation invokes this caller-defined object hook.
    def value.is_a?(*) = raise("must not call is_a?")
    values << value
    values
  end

  # Yields strings whose extension modules override identity checks with observable effects.
  # @yieldparam value [String] adversarial string
  # @yieldparam calls [Array] recorded hook calls
  # @yieldparam behavior [Symbol] identity-hook behavior
  def each_identity_hook_input
    %i[true false mutate raise].each do |behavior|
      value = +"text"
      calls = []
      extension = Module.new do
        private

        # Adds singleton behavior that value validation must reject.
        def hidden = :singleton_behavior
      end
      extension.define_singleton_method(:equal?) do |*|
        calls << behavior
        value.replace("changed") if behavior == :mutate
        raise "identity hook ran" if behavior == :raise

        behavior != false
      end
      value.extend(extension)
      yield value, calls, behavior
    end
  end

  # Commits a Ruby scalar and returns its raw root slot.
  # @param value [Object] scalar to encode
  # @return [XitDB::Core::Slot] committed slot
  def store(value)
    @core.transaction { |root| root.replace(XitDB::Ruby::Scalars.encode(value, core: @core)) }
    @core.root_cursor.slot
  end

  # Encodes and decodes a Ruby scalar through the test database.
  # @param value [Object] scalar to store
  # @param immutable [Boolean] whether decoded mutable values are frozen
  # @return [Object] decoded scalar
  def round_trip(value, immutable: true)
    XitDB::Ruby::Scalars.decode(store(value), core: @core, immutable: immutable)
  end

  # Decodes hand-written bytes to exercise malformed Ruby payloads.
  # @param hex [String] hexadecimal payload
  # @param format_tag [String] two-byte format tag
  # @param immutable [Boolean] whether decoded mutable values are frozen
  # @return [Object] decoded scalar
  def decode_payload(hex, format_tag: "rb", immutable: true)
    @core.transaction { |root| root.replace(@core.bytes([hex].pack("H*"), format_tag: format_tag)) }
    XitDB::Ruby::Scalars.decode(@core.root_cursor.slot, core: @core, immutable: immutable)
  end
end
