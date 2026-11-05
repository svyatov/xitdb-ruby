# frozen_string_literal: true

# Loads the advanced binary storage API in XitDB::Core.
#
# A Slot describes one value. A Cursor locates it. A Database owns the byte
# store and publishes root changes through a transaction.
# Collections in this API accept slots and encoded keys, not ordinary Ruby values.
# Most applications should start with XitDB::Database.
#
# @see XitDB::Core::Database
# @see XitDB::Core::Slot
# @see XitDB::Core::Cursor

require_relative "errors"
require_relative "core/format"
require_relative "core/hasher"
require_relative "core/crc64"
require_relative "core/memory_store"
require_relative "core/file_store"
require_relative "core/bytes"
require_relative "core/cursor"
require_relative "core/transaction"
require_relative "core/database"
require_relative "core/array_list"
require_relative "core/b_tree"
require_relative "core/linked_array_list"
require_relative "core/hash_map"
require_relative "core/sorted_map"
