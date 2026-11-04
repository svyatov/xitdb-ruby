# frozen_string_literal: true

module XitDB
  module Views
    class Map < Base
      UNSET = Object.new.freeze
      private_constant :UNSET

      def [](key)
        stored = adapter.lookup(key)
        context.profile.decode(stored, context: context, path: path + [key]) if stored
      end

      def fetch(key, default = UNSET)
        return self[key] if key?(key)
        return yield key if block_given?
        return default unless default.equal?(UNSET)

        raise KeyError, "key not found: #{key.inspect}"
      end

      def dig(*keys)
        raise ArgumentError, "at least one key is required" if keys.empty?

        value = self[keys.shift]
        return value if keys.empty? || value.nil?
        raise TypeError, "#{value.class} does not have #dig method" unless value.respond_to?(:dig)

        value.dig(*keys)
      end

      def key?(key)
        !adapter.lookup(key).nil?
      end

      def each_key
        return enum_for(__method__) unless block_given?

        each { |key, _value| yield key }
        self
      end

      def each_value
        return enum_for(__method__) unless block_given?

        each { |_key, value| yield value }
        self
      end

      def keys
        each_key.to_a
      end

      def values
        each_value.to_a
      end

      def []=(key, value)
        check!
        context.writable!
        present = key?(key)
        context.mutate(path) do |cursor|
          encoded = context.profile.encode(value, context: context, path: path + [key])
          collection = context.profile.container(cursor.slot, context: context, path: path)
          collection.assign(key, encoded)
          cursor.replace(collection.slot)
        end
        context.replace_location(path + [key])
        context.change_membership(path) unless present
        value
      end

      def delete(key)
        check!
        context.writable!
        return block_given? ? yield(key) : nil unless key?(key)

        # The removed value must remain readable after its old location expires.
        stored = adapter.lookup(key)
        context.transaction.freeze
        captured = Context.new(database: context.database, root: stored, bound: context.read_bound,
                               transaction: context.transaction)
        value = context.profile.decode(stored, context: captured, path: [])
        context.mutate(path) do |cursor|
          collection = context.profile.container(cursor.slot, context: context, path: path)
          collection.delete(key)
          cursor.replace(collection.slot)
        end
        context.replace_location(path + [key])
        context.change_membership(path)
        value
      end

      def clear
        check!
        context.writable!
        return self if empty?

        context.mutate(path) do |cursor|
          collection = context.profile.container(cursor.slot, context: context, path: path)
          collection.each_entry { |selector, _| collection.delete(selector) }
          cursor.replace(collection.slot)
        end
        context.invalidate_children(path)
        context.change_membership(path)
        self
      end

      def merge!(hash)
        check!
        context.writable!
        unless hash.instance_of?(Hash)
          raise TypeError, "merge! requires a Hash"
        end
        replaced = []
        added = false
        context.mutate(path) do |cursor|
          encoded = context.profile.encode(hash, context: context, path: path)
          input = context.profile.container(encoded, context: context, path: path)
          next if input.size.zero?

          collection = context.profile.container(cursor.slot, context: context, path: path)
          input.each_entry do |selector, stored|
            added = true unless collection.lookup(selector)
            collection.assign(selector, stored)
            replaced << selector
          end
          cursor.replace(collection.slot)
        end
        replaced.each { |selector| context.replace_location(path + [selector]) }
        context.change_membership(path) if added
        self
      end
    end
  end
end
