# frozen_string_literal: true

module XitDB
  module Views
    class Set < Base
      def include?(value)
        !adapter.lookup(value).nil?
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
        return self if empty?

        edit { |collection| collection.each_entry { |selector, _| collection.delete(selector) } }
        context.change_membership(path)
        self
      end

      private

      def edit
        context.mutate(path) do |cursor|
          collection = context.profile.container(cursor.slot, context: context, path: path)
          yield collection
          cursor.replace(collection.slot)
        end
      end
    end
  end
end
