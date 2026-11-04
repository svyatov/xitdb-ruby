# frozen_string_literal: true

module XitDB
  module Views
    module Sorted
      def rank(key)
        context.read { adapter.rank(key) }
      end

      def from(key)
        return enum_for(__method__, key) unless block_given?

        each_entries(-> { adapter.each_from(key) }) { |*entry| yield(*entry) }
      end

      def from_index(index)
        return enum_for(__method__, index) unless block_given?

        each_entries(-> { adapter.each_from_index(integer_argument(index)) }) { |*entry| yield(*entry) }
      end

      def page(offset:, limit:)
        check!
        offset = integer_argument(offset)
        limit = integer_argument(limit)
        raise ArgumentError, "negative page limit" if limit.negative?
        return enum_for(__method__, offset: offset, limit: limit) unless block_given?
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

    class SortedMap < Map
      include Sorted

      def merge!(hash)
        return super unless defined?(Profiles::Ruby) && context.profile.is_a?(Profiles::Ruby)

        check!
        context.writable!
        unless Object.instance_method(:instance_of?).bind_call(hash, Hash)
          raise TypeError, "merge! requires a Hash"
        end
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

    class SortedSet < Set
      include Sorted
    end
  end
end
