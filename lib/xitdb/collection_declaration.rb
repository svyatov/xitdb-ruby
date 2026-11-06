# frozen_string_literal: true

module XitDB
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
end
