# frozen_string_literal: true

module XitDB
  module Views
    class Set < Base
      def include?(value)
        context.read { !adapter.lookup(value).nil? }
      end

      def add(value)
        check!
        context.writable!
        return self if include?(value)

        edit { |collection| collection.assign(value, Core::Slot.new) }
        context.change_membership(path)
        self
      end

      def delete(value)
        check!
        context.writable!
        return self unless include?(value)

        edit { |collection| collection.delete(value) }
        context.change_membership(path)
        self
      end

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
