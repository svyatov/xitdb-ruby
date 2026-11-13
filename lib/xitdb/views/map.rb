# frozen_string_literal: true

module XitDB
  module Views
    # Provides key-based reads and writes for persistent maps.
    #
    # Portable maps require String keys. Ruby-profile maps accept typed keys
    # and preserve insertion order. Missing keys and stored nil both read as nil;
    # use {#key?} or {#fetch} when their difference matters.
    class Map < Base
      # Sentinel for an omitted default, distinct from an explicit nil.
      UNSET = MissingArgument.new.freeze
      private_constant :UNSET

      # Read a value, decoding a scalar or returning a nested collection view.
      # @param key [Object] key supported by the selected profile
      # @return [Object, nil] stored value, or nil when absent
      def [](key)
        context.read do
          stored = adapter.lookup(key)
          context.profile.decode(stored, context: context, path: path + [key]) if stored
        end
      end

      # Read a key with an explicit missing-key policy.
      #
      # A fallback block takes precedence over the default argument.
      # @param key [Object]
      # @param default [Object] fallback when absent; omitted means raise
      # @yield [key] compute a fallback for an absent key
      # @yieldparam key [Object]
      # @return [Object]
      # @raise [KeyError] if absent without a default or block
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

        case key
        when String then key = String.new(key)
        end
        raise KeyError, "key not found: #{key.inspect}"
      end

      # Follow keys and array positions through nested values.
      # @param keys [Array<Object>] successive selectors; at least one is required
      # @return [Object, nil] selected value, or nil when a step is absent
      # @raise [TypeError] if an intermediate value cannot be traversed
      def dig(*keys)
        context.read { dig_value(keys) }
      end

      # Resolve selectors one at a time, delegating to a scalar object's dig when supported.
      # @param keys [Array<Object>]
      # @return [Object, nil]
      def dig_value(keys)
        raise ArgumentError, "at least one key is required" if keys.empty?

        # @type var value: top
        value = self
        keys.each_with_index do |key, index|
          case value
          when nil then return nil
          when Map then value = value[key]
          when Array then value = value[integer_argument!(key)]
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

      # Test presence independently of the stored value, including a stored nil.
      # @param key [Object]
      # @return [Boolean]
      def key?(key)
        context.read { !adapter.lookup(key).nil? }
      end

      # Visit keys in this map's profile-defined order.
      # @yield [key]
      # @yieldparam key [Object]
      # @return [self, Enumerator] self with a block, otherwise an enumerator
      def each_key(&block)
        return enum_for(:each_key) unless block

        each_entries(-> { adapter.each_entry }, selectors_only: true, &block)
        self
      end

      # Visit values without building an intermediate Ruby Array.
      # @yield [value]
      # @yieldparam value [Object]
      # @return [self, Enumerator]
      def each_value
        return enum_for(:each_value) unless block_given?

        each { |_key, value| yield value }
        self
      end

      # Collect the keys into an independent Ruby Array.
      # @return [::Array<Object>]
      def keys
        context.read { each_key.to_a }
      end

      # Collect values into a Ruby Array; nested collections remain database views.
      # @return [::Array<Object>]
      # @see Base#to_ruby
      def values
        context.read { each_value.to_a }
      end

      # Insert or replace one entry in the active transaction.
      #
      # Replacing a collection expires views of that location and its children.
      # @param key [Object] key supported by the profile
      # @param value [Object] supported scalar, container, declaration, or compatible view
      # @return [Object] assigned value
      # @raise [ReadOnlyError] if this view is not writable
      # @raise [ForeignValueError] if an assigned view cannot share this storage
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

      # Remove an entry, returning its value or a fallback for an absent key.
      #
      # A removed collection remains a captured view until its transaction ends.
      # @param key [Object]
      # @yield [key] optional fallback when the key is absent
      # @yieldparam key [Object]
      # @return [Object, nil]
      # @raise [ReadOnlyError] if this view is not writable
      def delete(key)
        check!
        context.writable!
        return block_given? ? yield(key) : nil unless key?(key)

        context.check_stream_mutation!(path, targets: [path + [key]])

        value = nil
        context.mutate(path, targets: [path + [key]]) do |cursor|
          # Capture before deletion, with loaders inside the mutation checkpoint.
          stored = adapter.lookup(key) || raise(KeyError, "key no longer exists")
          context.writable_transaction!.freeze
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

      # Remove every entry and expire child views.
      # @return [self]
      # @raise [ReadOnlyError] if this view is not writable
      def clear
        check!
        context.writable!
        return self unless clear_entries

        context.invalidate_children(path)
        context.change_membership(path)
        self
      end

      # Assign all entries from a Ruby Hash as one logical mutation.
      #
      # An encoding failure leaves the map unchanged. Duplicate keys replace values.
      # @param hash [::Hash] entries to assign
      # @return [self]
      # @raise [TypeError] if the argument is not an exact Ruby Hash
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
