# frozen_string_literal: true

# Persistent collections with immutable snapshots and explicit transactions.
module XitDB
  # Explicit unsigned storage for an integer.
  class UInt
    # @return [Integer] unsigned value represented by this wrapper
    attr_reader :value

    # Validate and freeze an explicitly unsigned 64-bit integer.
    # @param value [Integer] integer from zero through 2**64 - 1
    # @raise [RangeError] if the integer is outside that range
    def initialize(value)
      @value = Core::Format.integer(value, 0..Core::Format::UINT64_MAX)
      freeze
    end
  end

  # Describes the storage layout of a new empty collection.
  class CollectionDeclaration
    # Physical collection layouts accepted by this declaration.
    KINDS = %i[hash_map counted_hash_map hash_set counted_hash_set array_list linked_array_list sorted_map
               sorted_set].freeze

    # @!attribute [r] kind
    #   Physical layout to create when the declaration is assigned.
    #   @return [Symbol]
    # @!attribute [r] key_kind
    #   Declared sorted key type, or nil when the profile chooses its default.
    #   @return [Symbol, nil]
    attr_reader :kind, :key_kind

    # Describe an empty collection to create when assigned in a transaction.
    # @param kind [Symbol] supported physical collection kind
    # @param key [Symbol, nil] sorted key kind: :string, :integer, :float, or :time
    # @raise [ArgumentError] if the kind or key declaration is unsupported
    def initialize(kind, key: nil)
      raise ArgumentError, "unknown collection kind" unless KINDS.include?(kind)
      if !nil.equal?(key) && (!%i[sorted_map sorted_set].include?(kind) || !%i[string integer float time].include?(key))
        raise ArgumentError, "sorted key kind must be :string, :integer, :float, or :time"
      end

      @kind = kind
      @key_kind = key
      freeze
    end

    # Report whether the hash layout stores its entry count.
    # @return [Boolean]
    def counted?
      %i[counted_hash_map counted_hash_set].include?(kind)
    end
  end

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
