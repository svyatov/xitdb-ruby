# frozen_string_literal: true

require_relative "../xitdb"
require_relative "ruby/scalars"
require_relative "ruby/key_encoding"
require_relative "ruby/containers"
require_relative "profiles/ruby"

module XitDB
  module Ruby
    def self.open(path, readonly: false, lock_timeout: 5.0, codecs: [])
      profile = Profiles::Ruby.new(codecs: codecs)
      store, created = Database.send(:open_store, path, readonly: readonly)
      begin
        core = Core::Database.new(store: store, initialize_empty: created, lock_timeout: lock_timeout,
                                  hash_id: "rb01", hash_size: 32)
        database = Database.new(core: core, profile: profile, readonly: readonly)
      rescue Exception
        store.close rescue nil
        raise
      end
      return database unless block_given?

      begin
        yield database
      ensure
        database.close
      end
    end

    def self.memory(codecs: [])
      profile = Profiles::Ruby.new(codecs: codecs)
      database = Database.new(core: Core::Database.memory(hash_id: "rb01", hash_size: 32), profile: profile)
      return database unless block_given?

      begin
        yield database
      ensure
        database.close
      end
    end
  end
end
