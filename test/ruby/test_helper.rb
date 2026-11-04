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
