# frozen_string_literal: true

# Persistent collections with immutable snapshots and explicit transactions.
module XitDB
  # Explicit unsigned storage for an integer.
  class UInt
    attr_reader :value

    def initialize(value)
      @value = Core::Format.integer(value, 0..Core::Format::UINT64_MAX)
      freeze
    end
  end

  # Describes the storage layout of a new empty collection.
  class CollectionDeclaration
    KINDS = %i[hash_map counted_hash_map hash_set counted_hash_set array_list linked_array_list sorted_map
               sorted_set].freeze

    attr_reader :kind, :key_kind

    def initialize(kind, key: nil)
      raise ArgumentError, "unknown collection kind" unless KINDS.include?(kind)
      if !nil.equal?(key) && (!%i[sorted_map sorted_set].include?(kind) || !%i[string integer float time].include?(key))
        raise ArgumentError, "sorted key kind must be :string, :integer, :float, or :time"
      end

      @kind = kind
      @key_kind = key
      freeze
    end

    def counted?
      %i[counted_hash_map counted_hash_set].include?(kind)
    end
  end

  def self.uint(value)
    UInt.new(value)
  end

  def self.bytes(bytes, format_tag: nil)
    Core::ByteValue.new(bytes, format_tag: format_tag)
  end

  def self.map(counted: false)
    raise ArgumentError, "counted must be true or false" unless counted.equal?(true) || counted.equal?(false)

    CollectionDeclaration.new(counted ? :counted_hash_map : :hash_map)
  end

  def self.set(counted: false)
    raise ArgumentError, "counted must be true or false" unless counted.equal?(true) || counted.equal?(false)

    CollectionDeclaration.new(counted ? :counted_hash_set : :hash_set)
  end

  def self.array
    CollectionDeclaration.new(:array_list)
  end

  def self.linked_array
    CollectionDeclaration.new(:linked_array_list)
  end

  def self.sorted_map(key: nil)
    CollectionDeclaration.new(:sorted_map, key: key)
  end

  def self.sorted_set(key: nil)
    CollectionDeclaration.new(:sorted_set, key: key)
  end
end
