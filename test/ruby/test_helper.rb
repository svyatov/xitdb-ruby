# frozen_string_literal: true

require_relative "../test_helper"
require "xitdb/ruby/wire"
require "xitdb/ruby/key_encoding"
require "xitdb/ruby/scalars"

class RubyProfileTest < Minitest::Test
  def setup
    @core = XitDB::Core::Database.memory(hash_id: "rb01", hash_size: 32)
  end

  def teardown
    @core.close
  end

  def key_bytes(value)
    XitDB::Ruby::KeyEncoding.dump(value)
  end

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

      def hidden = true
    end
    values << (+"text").extend(extension)
    values << (+"text").extend(extension).freeze
    value = +"text"
    value.singleton_class.prepend(extension)
    values << value
    value = +"text"
    class << value
      private

      def bytesize = raise("must reject before bytesize")
    end
    values << value
    value = +"text"
    def value.singleton_methods(*) = []
    def value.singleton_class = raise("must not call singleton_class")
    def value.class = raise("must not call class")
    def value.is_a?(*) = raise("must not call is_a?")
    values << value
    values
  end

  def each_identity_hook_input
    %i[true false mutate raise].each do |behavior|
      value = +"text"
      calls = []
      extension = Module.new do
        private

        def hidden = true
      end
      extension.define_singleton_method(:equal?) do |*|
        calls << behavior
        value.replace("changed") if behavior == :mutate
        raise "identity hook ran" if behavior == :raise

        behavior != :false
      end
      value.extend(extension)
      yield value, calls, behavior
    end
  end

  def store(value)
    @core.transaction { |root| root.replace(XitDB::Ruby::Scalars.encode(value, core: @core)) }
    @core.root_cursor.slot
  end

  def round_trip(value, immutable: true)
    XitDB::Ruby::Scalars.decode(store(value), core: @core, immutable: immutable)
  end

  def decode_payload(hex, format_tag: "rb", immutable: true)
    @core.transaction { |root| root.replace(@core.bytes([hex].pack("H*"), format_tag: format_tag)) }
    XitDB::Ruby::Scalars.decode(@core.root_cursor.slot, core: @core, immutable: immutable)
  end
end
