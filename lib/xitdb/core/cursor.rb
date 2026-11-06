# frozen_string_literal: true

module XitDB
  module Core
    # A view locating a root value or one nested collection element.
    #
    # Read-only cursors retain a byte boundary. Writable cursors follow copied ancestor paths inside their transaction.
    #
    # Replacing a value invalidates child views. Ending a transaction expires its writable views.
    class Cursor
      # @!attribute [r] database
      #   Database that owns this view.
      #   @return [Database]
      # @!attribute [r] transaction
      #   Writable transaction, or nil for a read-only view.
      #   @return [Transaction, nil]
      attr_reader :database, :transaction

      # Creates a view of one slot with an explicit read boundary.
      # @param database [Database] database that owns the stored records
      # @param slot [Slot] stored value or record descriptor
      # @param bound [Integer] exclusive upper byte boundary for reads
      # @param transaction [Transaction] active destination transaction
      # @return [Cursor]
      def initialize(database:, slot:, bound:, transaction: nil)
        @database = database
        @slot = slot
        @bound = bound
        @transaction = transaction
        @valid = true
        @children = ObjectSpace::WeakMap.new
      end

      # Resolves the current slot through ancestors and checks view validity.
      # @return [Slot]
      # @raise [ExpiredViewError] if this view or an ancestor was replaced, removed, or discarded
      # @raise [ClosedError] if the database is closed
      def slot
        database.check_open!
        # @type var path: Array[Cursor]
        path = []
        ancestor = self
        loop do
          transaction&.check_cursor!(ancestor)
          raise ExpiredViewError, "cursor ancestor was replaced" unless ancestor.valid?
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

      # Returns the storage boundary after checking view validity.
      # @return [Integer]
      def bound
        slot
        transaction ? transaction.length : @bound
      end

      # Replaces this value and invalidates views of its former children.
      # @param slot [Slot] stored value or record descriptor
      # @return [self]
      # @raise [ReadOnlyError] if this cursor has no transaction
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

      # Finds a child by index or encoded key for a collection kind.
      # @param kind [Symbol] requested collection slot tag
      # @param selector [Integer, String] array index or encoded collection key
      # @return [Cursor, nil]
      # @raise [ArgumentError] if kind is unsupported
      # @raise [TypeError] if selector has the wrong type for the collection
      def child(kind:, selector:)
        unless %i[array_list linked_array_list sorted_map sorted_set].include?(kind) || HashMap::TAGS.include?(kind)
          raise ArgumentError, "unsupported child kind: #{kind.inspect}"
        end
        return nil if slot.tag == :none

        if kind == :array_list
          ArrayList.new(self).cursor_at(integer_selector!(selector))
        elsif kind == :linked_array_list
          LinkedArrayList.new(self).cursor_at(integer_selector!(selector))
        elsif %i[sorted_map sorted_set].include?(kind)
          SortedMap.new(self).cursor_at(string_selector!(selector))
        else
          HashMap.from_cursor(self).cursor_at(string_selector!(selector))
        end
      end

      # Publishes a copied collection path while retaining valid child views.
      # @param slot [Slot] stored value or record descriptor
      # @param propagate [Boolean] whether to update parent collection paths immediately
      # @return [self]
      # @raise [ReadOnlyError] if this cursor has no transaction
      # @api private
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

      # Finds or creates a child view for an array position.
      # @param index [Integer] zero-based element index; supported negative indexes count from the end
      # @param slot [Slot] stored value or record descriptor
      # @return [Cursor]
      # @api private
      def array_child(index, slot)
        cached_child(index, slot)
      end

      # Finds or creates a child view for an encoded collection key.
      # @param hash_bytes [String] precomputed binary digest with the database header hash width
      # @param slot [Slot] stored value or record descriptor
      # @return [Cursor]
      # @api private
      def hash_child(hash_bytes, slot)
        cached_child(hash_bytes, slot)
      end

      # Reuses a valid child view or registers a new one.
      # @param index [Integer, String] array index or encoded collection key
      # @param slot [Slot] stored value or record descriptor
      # @return [Cursor]
      # @api private
      def cached_child(index, slot)
        @children.each_pair do |child, selector|
          next unless selector == index && child.valid?

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

      # Invalidates selected child views after replacement, removal, or index shifts.
      # @param index [Integer, String, nil] exact child selector to invalidate, or nil for all selectors
      # @param from [Integer, nil] first array index whose views to invalidate
      # @param except [Cursor, nil] child view to keep valid
      # @return [void]
      # @api private
      def invalidate_children(index: nil, from: nil, except: nil)
        @children.each_pair do |child, selector|
          next if child.equal?(except)
          next if index && selector != index
          next if from && selector < from

          child.instance_variable_set(:@valid, false)
        end
      end

      # Captures the local slot and validity flag for rollback.
      # @return [Array(Slot, Boolean)]
      # @api private
      def checkpoint_state
        [@slot, @valid]
      end

      # Restores a saved local slot and validity flag.
      # @param state [Array(Slot, Boolean)] saved slot and validity flag
      # @return [Array(Slot, Boolean)]
      # @api private
      def restore_checkpoint_state(state)
        @slot, @valid = state
      end

      # Reads this cursor's byte value inside its storage boundary.
      # @return [ByteValue]
      def read_bytes
        database.read_bytes(slot, bound: bound)
      end

      protected

      # Reads a collection slot using a checked selector.
      def collection_get(selector)
        target = collection
        if target.is_a?(ArrayList) || target.is_a?(LinkedArrayList)
          target.get(integer_selector!(selector))
        else
          target.get(string_selector!(selector))
        end
      end

      # Updates a child and forwards ownership and ancestor propagation options.
      def collection_replace(selector, slot, owner: nil, collection: false, propagate: true)
        target = self.collection
        if target.is_a?(ArrayList) || target.is_a?(LinkedArrayList)
          target.replace_child(integer_selector!(selector), slot, owner: owner, collection: collection,
                                                                  propagate: propagate)
        else
          target.replace_child(string_selector!(selector), slot, owner: owner, collection: collection,
                                                                 propagate: propagate)
        end
      end

      # Checks that an array selector is an Integer.
      def integer_selector!(selector)
        raise TypeError, "array index must be an Integer" unless selector.is_a?(Integer)

        selector
      end

      # Checks that a collection selector is a String.
      def string_selector!(selector)
        raise TypeError, "collection key must be a String" unless selector.is_a?(String)

        selector
      end

      # @!attribute [r] parent
      #   Ancestor view that contains this element.
      #   @return [Cursor, nil]
      # @!attribute [r] selector
      #   Index or encoded key locating this child in its parent.
      #   @return [Integer, String]
      attr_reader :parent, :selector

      # Reports whether this view has avoided explicit invalidation.
      # @return [Boolean]
      def valid?
        @valid
      end

      # Chooses the collection reader from the current slot tag.
      def collection
        case slot.tag
        when :array_list then ArrayList.new(self)
        when :linked_array_list then LinkedArrayList.new(self)
        when :sorted_map, :sorted_set then SortedMap.new(self)
        when :hash_map, :hash_set, :counted_hash_map, :counted_hash_set then HashMap.from_cursor(self)
        else raise InvalidValueError, "slot does not contain a supported collection"
        end
      end

      # Returns the saved slot without resolving the ancestor path.
      def local_slot
        @slot
      end
    end
  end
end
