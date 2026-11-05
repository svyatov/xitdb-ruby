# frozen_string_literal: true

module XitDB
  module Core
    # Tracks a bounded collection slot and its ancestor path.
    class Cursor
      attr_reader :database, :transaction

      def initialize(database:, slot:, bound:, transaction: nil)
        @database = database
        @slot = slot
        @bound = bound
        @transaction = transaction
        @valid = true
        @children = ObjectSpace::WeakMap.new
      end

      def slot
        database.check_open!
        # @type var path: Array[Cursor]
        path = []
        ancestor = self
        loop do
          transaction&.check_cursor!(ancestor)
          raise ExpiredViewError, "cursor ancestor was replaced" unless ancestor.valid
          break unless ancestor.parent

          path << ancestor
          ancestor = ancestor.parent
        end
        value = ancestor.local_slot
        limit = transaction ? transaction.length : @bound
        path.reverse_each do |child|
          reader = self.class.new(database: database, slot: value, bound: limit)
          value = reader.collection_get(child.selector)
          raise ExpiredViewError, "cursor element was removed" unless value

          child.instance_variable_set(:@slot, value)
        end
        value
      end

      def bound
        slot
        transaction ? transaction.length : @bound
      end

      def replace(slot)
        database.check_open!
        raise ReadOnlyError, "cursor is read-only" unless transaction

        transaction.check_replacement!(self, slot)
        self.slot
        parent = @parent
        parent&.collection_replace(@selector, slot, owner: self)
        @slot = slot
        invalidate_children
        self
      end

      def child(kind:, selector:)
        unless %i[array_list linked_array_list sorted_map sorted_set].include?(kind) || HashMap::TAGS.include?(kind)
          raise ArgumentError, "unsupported child kind: #{kind.inspect}"
        end
        return nil if slot.tag == :none

        if kind == :array_list
          ArrayList.new(self).cursor_at(integer_selector(selector))
        elsif kind == :linked_array_list
          LinkedArrayList.new(self).cursor_at(integer_selector(selector))
        elsif %i[sorted_map sorted_set].include?(kind)
          SortedMap.new(self).cursor_at(string_selector(selector))
        else
          HashMap.from_cursor(self).cursor_at(string_selector(selector))
        end
      end

      # Collection updates keep child paths live while replacing copied ancestors.
      def update_collection(slot, propagate: true)
        transaction = self.transaction
        raise ReadOnlyError, "cursor is read-only" unless transaction

        transaction.check_replacement!(self, slot)
        self.slot
        @slot = slot
        if propagate
          child = self
          while child.parent
            parent = child.parent
            parent.collection_replace(child.selector, child.local_slot, collection: true, propagate: false)
            child = parent
          end
        end
        self
      end

      def array_child(index, slot)
        cached_child(index, slot)
      end

      def hash_child(hash_bytes, slot)
        cached_child(hash_bytes, slot)
      end

      def cached_child(index, slot)
        @children.each_pair do |child, selector|
          next unless selector == index && child.valid

          begin
            child.slot
          rescue ExpiredViewError
            next
          end
          return child
        end
        child = if transaction
                  transaction.cursor(slot: slot)
                else
                  self.class.new(database: database, slot: slot, bound: bound)
                end
        child.instance_variable_set(:@parent, self)
        child.instance_variable_set(:@selector, index)
        @children[child] = index
        child
      end

      def invalidate_children(index: nil, from: nil, except: nil)
        @children.each_pair do |child, selector|
          next if child.equal?(except)
          next if index && selector != index
          next if from && selector < from

          child.instance_variable_set(:@valid, false)
        end
      end

      # These states are internal transaction snapshots, including invalid views.
      def checkpoint_state
        [@slot, @valid]
      end

      def restore_checkpoint_state(state)
        @slot, @valid = state
      end

      def read_bytes
        database.read_bytes(slot, bound: bound)
      end

      protected

      def collection_get(selector)
        target = collection
        if target.is_a?(ArrayList) || target.is_a?(LinkedArrayList)
          target.get(integer_selector(selector))
        else
          target.get(string_selector(selector))
        end
      end

      def collection_replace(selector, slot, owner: nil, collection: false, propagate: true)
        target = self.collection
        if target.is_a?(ArrayList) || target.is_a?(LinkedArrayList)
          target.replace_child(integer_selector(selector), slot, owner: owner, collection: collection,
                                                                 propagate: propagate)
        else
          target.replace_child(string_selector(selector), slot, owner: owner, collection: collection,
                                                                propagate: propagate)
        end
      end

      def integer_selector(selector)
        raise TypeError, "array index must be an Integer" unless selector.is_a?(Integer)

        selector
      end

      def string_selector(selector)
        raise TypeError, "collection key must be a String" unless selector.is_a?(String)

        selector
      end

      attr_reader :parent, :selector, :valid

      def collection
        case slot.tag
        when :array_list then ArrayList.new(self)
        when :linked_array_list then LinkedArrayList.new(self)
        when :sorted_map, :sorted_set then SortedMap.new(self)
        when :hash_map, :hash_set, :counted_hash_map, :counted_hash_set then HashMap.from_cursor(self)
        else raise InvalidValueError, "slot does not contain a supported collection"
        end
      end

      def local_slot
        @slot
      end
    end
  end
end
