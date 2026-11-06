# frozen_string_literal: true

module XitDB
  module Views
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
  end
end
