# frozen_string_literal: true

require_relative "../xitdb"
require_relative "page_codec"
require_relative "ruby/scalars"
require_relative "ruby/key_encoding"
require_relative "ruby/containers"
require_relative "ruby/packed_map"
require_relative "ruby/packed_array"
require_relative "ruby/packing_state"
require_relative "ruby/page_reference"
require_relative "ruby/page_cell"
require_relative "ruby/pages"
require_relative "ruby/page_row"
require_relative "ruby/page_array"
require_relative "profiles/ruby"

module XitDB
  # Opens file-backed and in-memory databases that preserve Ruby value types.
  # The Ruby profile retains string encodings, insertion order, and registered application values.
  # Its files use the Ruby profile hash identifier and require the Ruby profile to reopen.
  #
  # @example Create and close an in-memory database
  #   XitDB::Ruby.memory do |db|
  #     db.transaction { |root| root["enabled"] = true }
  #     db.snapshot["enabled"] # => true
  #   end
  module Ruby
    # Opens a Ruby-profile file, or creates it when writable and absent.
    # With a block, closes the database after the block, including when the block raises.
    #
    # @param path [String] database file path
    # @param readonly [Boolean] whether to reject writes and require an existing file
    # @param lock_timeout [Float] seconds to wait for a writer lock
    # @param codecs [Array<Codec>] application serializers needed to read or write custom values
    # @return [Database, Object] the open database, or the block result
    # @yield [database] uses the open database
    # @yieldparam database [Database] database closed when the block finishes
    # @yieldreturn [Object] result returned by this method
    # @raise [CodecConfigurationError] if codec registrations are invalid
    # @raise [ProfileMismatchError] if the file header does not match this profile
    def self.open(path, readonly: false, lock_timeout: 5.0, codecs: [])
      profile = Profiles::Ruby.new(codecs: codecs)
      store, created = Database.send(:open_store, path, readonly: readonly)
      opened = false
      # @type var database: Database
      begin
        core = Core::Database.new(store: store, initialize_empty: created, lock_timeout: lock_timeout,
                                  hash_id: "rb03", hash_size: 32)
        database = Database.new(core: core, profile: profile, readonly: readonly)
        opened = true
      ensure
        store.send(:close_unreturned) unless opened
      end
      return database unless block_given?

      begin
        yield database
      ensure
        database.close
      end
    end

    # Creates a Ruby-profile database held in memory.
    # With a block, closes the database after the block, including when the block raises.
    #
    # @param codecs [Array<Codec>] application serializers for custom values
    # @return [Database, Object] the open database, or the block result
    # @yield [database] uses the temporary database
    # @yieldparam database [Database] database closed when the block finishes
    # @yieldreturn [Object] result returned by this method
    # @raise [CodecConfigurationError] if codec registrations are invalid
    def self.memory(codecs: [])
      profile = Profiles::Ruby.new(codecs: codecs)
      database = Database.new(core: Core::Database.memory(hash_id: "rb03", hash_size: 32), profile: profile)
      return database unless block_given?

      begin
        yield database
      ensure
        database.close
      end
    end
  end
end
