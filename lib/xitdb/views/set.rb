# frozen_string_literal: true

module XitDB
  module Views
    # Provides membership reads and writes for persistent sets.
    class Set < Base
      # Test whether a member is present using the profile's key identity rules.
      # @param value [Object] supported set member
      # @return [Boolean]
      def include?(value)
        context.read { !adapter.lookup(value).nil? }
      end

      # Add a member once; adding a present member leaves membership unchanged.
      # @param value [Object]
      # @return [self]
      # @raise [ReadOnlyError] unless this view is writable
      def add(value)
        check!
        context.writable!
        return self if include?(value)

        edit { |collection| collection.assign(value, Core::Slot.new) }
        context.change_membership(path)
        self
      end

      # Remove a member if present.
      # @param value [Object]
      # @return [self]
      def delete(value)
        check!
        context.writable!
        return self unless include?(value)

        edit { |collection| collection.delete(value) }
        context.change_membership(path)
        self
      end

      # Remove all members.
      # @return [self]
      def clear
        check!
        context.writable!
        return self unless clear_entries

        context.change_membership(path)
        self
      end
    end
  end
end
