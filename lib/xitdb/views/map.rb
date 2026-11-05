# frozen_string_literal: true

module XitDB
  module Views
    class Map < Base
      UNSET = Object.new.freeze
      private_constant :UNSET

      def [](key)
        context.read do
          stored = adapter.lookup(key)
          context.profile.decode(stored, context: context, path: path + [key]) if stored
        end
      end

      def fetch(key, default = UNSET)
        found, value = context.read do
          present = key?(key)
          [present, present ? self[key] : nil]
        end
        return value if found
        return yield key if block_given?
        return default unless default.equal?(UNSET)

        raise KeyError, "key not found: #{key.inspect}"
      end

      def dig(*keys)
        context.read { dig_value(keys) }
      end

      def dig_value(keys)
        raise ArgumentError, "at least one key is required" if keys.empty?

        value = self
        keys.each_with_index do |key, index|
          return nil if value.nil?

          case value
          when Map then value = value[key]
          when Array then value = value[integer_argument(key)]
          else
            raise TypeError, "#{value.class} does not have #dig method" unless value.respond_to?(:dig)

            return value.dig(*keys.drop(index))
          end
        end
        value
      end
      private :dig_value

      def key?(key)
        context.read { !adapter.lookup(key).nil? }
      end

      def each_key
        return enum_for(__method__) unless block_given?

        each_entries(-> { adapter.each_entry }, selectors_only: true) { |key| yield key }
        self
      end

      def each_value
        return enum_for(__method__) unless block_given?

        each { |_key, value| yield value }
        self
      end

      def keys
        context.read { each_key.to_a }
      end

      def values
        context.read { each_value.to_a }
      end

      def []=(key, value)
        check!
        context.writable!
        present = key?(key)
        context.mutate(path, targets: [path + [key]]) do |cursor|
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

        context.check_stream_mutation!(path, targets: [path + [key]])

        value = nil
        context.mutate(path, targets: [path + [key]]) do |cursor|
          # Capture before deletion, with loaders inside the mutation checkpoint.
          stored = adapter.lookup(key)
          context.transaction.freeze
          captured = Context.new(database: context.database, root: stored, bound: context.read_bound,
                                 transaction: context.transaction)
          value = context.profile.decode(stored, context: captured, path: [])
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
        return self unless clear_entries

        context.invalidate_children(path)
        context.change_membership(path)
        self
      end

      def merge!(hash)
        check!
        context.writable!
        unless Object.instance_method(:instance_of?).bind_call(hash, Hash)
          raise TypeError, "merge! requires a Hash"
        end
        replaced = []
        added = false
        targets = Hash.instance_method(:keys).bind_call(hash).map { |key| path + [key] }
        context.mutate(path, targets: targets) do |cursor|
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
