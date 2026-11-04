# frozen_string_literal: true

module XitDB
  class UInt
    attr_reader :value

    def initialize(value)
      @value = Core::Format.integer(value, 0..Core::Format::UINT64_MAX)
      freeze
    end
  end

  class CollectionDeclaration
    KINDS = %i[hash_map counted_hash_map hash_set counted_hash_set array_list linked_array_list sorted_map sorted_set].freeze

    attr_reader :kind

    def initialize(kind)
      raise ArgumentError, "unknown collection kind" unless KINDS.include?(kind)

      @kind = kind
      freeze
    end

    def counted?
      kind == :counted_hash_map || kind == :counted_hash_set
    end
  end

  def self.uint(value)
    UInt.new(value)
  end

  def self.bytes(bytes, format_tag: nil)
    Core::ByteValue.new(bytes, format_tag: format_tag)
  end

  def self.map(counted: false)
    unless counted.equal?(true) || counted.equal?(false)
      raise ArgumentError, "counted must be true or false"
    end

    CollectionDeclaration.new(counted ? :counted_hash_map : :hash_map)
  end

  def self.set(counted: false)
    unless counted.equal?(true) || counted.equal?(false)
      raise ArgumentError, "counted must be true or false"
    end

    CollectionDeclaration.new(counted ? :counted_hash_set : :hash_set)
  end

  def self.array
    CollectionDeclaration.new(:array_list)
  end

  def self.linked_array
    CollectionDeclaration.new(:linked_array_list)
  end

  def self.sorted_map
    CollectionDeclaration.new(:sorted_map)
  end

  def self.sorted_set
    CollectionDeclaration.new(:sorted_set)
  end
end
