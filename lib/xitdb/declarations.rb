# frozen_string_literal: true

# Persistent collections with immutable snapshots and explicit transactions.
module XitDB
  # Request unsigned integer storage explicitly.
  # @param value [Integer] integer from zero through 2**64 - 1
  # @return [UInt]
  # @example Assign an unsigned integer
  #   root["counter"] = XitDB.uint(42)
  def self.uint(value)
    UInt.new(value)
  end

  # Wrap bytes with an optional two-byte label describing their meaning.
  #
  # A format tag labels bytes; the storage core does not interpret their contents.
  # @param bytes [String] raw content
  # @param format_tag [String, nil] optional two-byte format identifier
  # @return [Core::ByteValue]
  def self.bytes(bytes, format_tag: nil)
    Core::ByteValue.new(bytes, format_tag: format_tag)
  end

  # Declare an empty hash map with an optional stored entry count.
  # @param counted [Boolean] store counts for direct size lookup
  # @return [CollectionDeclaration]
  # @example Create a nested map
  #   root["users"] = XitDB.map(counted: true)
  def self.map(counted: false)
    raise ArgumentError, "counted must be true or false" unless counted.equal?(true) || counted.equal?(false)

    CollectionDeclaration.new(counted ? :counted_hash_map : :hash_map)
  end

  # Declare an empty set with an optional stored member count.
  # @param counted [Boolean]
  # @return [CollectionDeclaration]
  def self.set(counted: false)
    raise ArgumentError, "counted must be true or false" unless counted.equal?(true) || counted.equal?(false)

    CollectionDeclaration.new(counted ? :counted_hash_set : :hash_set)
  end

  # Declare an empty array indexed by integer position.
  # @return [CollectionDeclaration]
  def self.array
    CollectionDeclaration.new(:array_list)
  end

  # Declare an empty array backed by a tree with positional insert and delete operations.
  # @return [CollectionDeclaration]
  def self.linked_array
    CollectionDeclaration.new(:linked_array_list)
  end

  # Declare an empty map whose keys are visited in storage order.
  # @param key [Symbol, nil] :string, :integer, :float, or :time; profile rules determine the default
  # @return [CollectionDeclaration]
  # @see Views::Sorted
  def self.sorted_map(key: nil)
    CollectionDeclaration.new(:sorted_map, key: key)
  end

  # Declare an empty set whose members are visited in storage order.
  # @param key [Symbol, nil] :string, :integer, :float, or :time; profile rules determine the default
  # @return [CollectionDeclaration]
  def self.sorted_set(key: nil)
    CollectionDeclaration.new(:sorted_set, key: key)
  end
end

require_relative "uint"
require_relative "collection_declaration"
