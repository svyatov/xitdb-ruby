# frozen_string_literal: true

module XitDB
  module Views
    # Adds ordered iteration and pagination to sorted collection views.
    module Sorted
      # Count keys or members that sort before the supplied key.
      #
      # The key need not exist. The result is its insertion position.
      # @param key [Object] key matching this sorted collection's key kind
      # @return [Integer] zero-based insertion position
      def rank(key)
        context.read { adapter.rank(key) }
      end

      # Visit entries starting at the first key greater than or equal to key.
      # @param key [Object]
      # @yield [*entry] key/value for maps, member for sets
      # @return [self, Enumerator]
      def from(key)
        return enum_for(:from, key) unless block_given?

        each_entries(-> { adapter.each_from(key) }) { |*entry| yield(*entry) }
        self
      end

      # Visit entries starting at a position in sorted order.
      # @param index [Integer] zero-based sorted position
      # @yield [*entry] key/value for maps, member for sets
      # @return [self, Enumerator]
      def from_index(index)
        return enum_for(:from_index, index) unless block_given?

        each_entries(-> { adapter.each_from_index(integer_argument(index)) }) { |*entry| yield(*entry) }
        self
      end

      # Visit at most limit entries starting at a sorted position.
      # @param offset [Integer] starting position
      # @param limit [Integer] nonnegative maximum number of entries
      # @yield [*entry] key/value for maps, member for sets
      # @return [self, Enumerator]
      # @raise [ArgumentError] if limit is negative
      def page(offset:, limit:)
        check!
        offset = integer_argument(offset)
        limit = integer_argument(limit)
        raise ArgumentError, "negative page limit" if limit.negative?
        return enum_for(:page, offset: offset, limit: limit) unless block_given?
        return self if limit.zero?

        remaining = limit
        from_index(offset) do |*entry|
          yield(*entry)
          remaining -= 1
          break if remaining.zero?
        end
        self
      end
    end

    # A map whose keys have a stable storage order.
    class SortedMap < Map
      include Sorted

      # Assign a Ruby Hash while preserving this map's declared sorted key kind.
      # @param hash [::Hash]
      # @return [self]
      # @raise [TypeError] if the argument is not an exact Ruby Hash
      def merge!(hash)
        return super unless defined?(Profiles::Ruby) && context.profile.is_a?(Profiles::Ruby)

        check!
        context.writable!
        raise TypeError, "merge! requires a Hash" unless Object.instance_method(:instance_of?).bind_call(hash, Hash)

        # @type var replaced: ::Array[selector]
        replaced = []
        added = false
        targets = Hash.instance_method(:keys).bind_call(hash).map { |key| path + [key] }
        edit(targets: targets) do |collection|
          context.profile.input_kind(hash, path: path)
          hash.each_pair do |key, value|
            added = true unless collection.lookup(key)
            stored = context.profile.encode(value, context: context, path: path + [key])
            collection.assign(key, stored)
            replaced << key
          end
        end
        replaced.each { |key| context.replace_location(path + [key]) }
        context.change_membership(path) if added
        self
      end
    end

    # A set visited in key order, with rank lookup and bounded pagination.
    class SortedSet < Set
      include Sorted
    end
  end
end
