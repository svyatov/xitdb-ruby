# frozen_string_literal: true

module XitDB
  module Views
    # Provides key-based reads and writes for persistent maps.
    class Map < Base
      UNSET = MissingArgument.new.freeze
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

        case default
        when MissingArgument then nil
        else return default
        end

        raise KeyError, "key not found: #{key.inspect}"
      end

      def dig(*keys)
        context.read { dig_value(keys) }
      end

      def dig_value(keys)
        raise ArgumentError, "at least one key is required" if keys.empty?

        # @type var value: top
        value = self
        keys.each_with_index do |key, index|
          case value
          when nil then return nil
          when Map then value = value[key]
          when Array then value = value[integer_argument(key)]
          when Object
            raise TypeError, "#{value.class} does not have #dig method" unless value.respond_to?(:dig)

            return Object.instance_method(:public_method).bind_call(value, :dig).call(*keys.drop(index))
          else
            raise TypeError, "value does not have #dig method"
          end
        end
        value
      end
      private :dig_value

      def key?(key)
        context.read { !adapter.lookup(key).nil? }
      end

      def each_key(&block)
        return enum_for(:each_key) unless block

        each_entries(-> { adapter.each_entry }, selectors_only: true) { |key| block.call(key) }
        self
      end

      def each_value
        return enum_for(:each_value) unless block_given?

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
          collection = context.collection(cursor.slot, path: path)
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
          stored = adapter.lookup(key) || raise(KeyError, "key no longer exists")
          context.writable_transaction.freeze
          captured = Context.new(database: context.database, root: stored, bound: context.read_bound,
                                 transaction: context.transaction)
          value = context.profile.decode(stored, context: captured, path: [])
          collection = context.collection(cursor.slot, path: path)
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
        return self unless clear_entries?

        context.invalidate_children(path)
        context.change_membership(path)
        self
      end

      def merge!(hash)
        check!
        context.writable!
        raise TypeError, "merge! requires a Hash" unless Object.instance_method(:instance_of?).bind_call(hash, Hash)

        # @type var replaced: ::Array[selector]
        replaced = []
        added = false
        targets = Hash.instance_method(:keys).bind_call(hash).map { |key| path + [key] }
        context.mutate(path, targets: targets) do |cursor|
          encoded = context.profile.encode(hash, context: context, path: path)
          input = context.collection(encoded, path: path)
          next if input.empty?

          collection = context.collection(cursor.slot, path: path)
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
