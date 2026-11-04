# frozen_string_literal: true

module XitDB
  # Owns one captured root or one transaction's logical root.
  class Context
    Location = Struct.new(:path, :membership, :expired)
    private_constant :Location

    attr_reader :database, :profile, :transaction, :root

    def initialize(database:, root:, bound:, transaction: nil, readonly: false)
      @database = database
      @profile = database.profile
      @root = root
      @bound = bound
      @transaction = transaction
      @readonly = readonly
      @changed = false
      @locations = ObjectSpace::WeakMap.new if transaction && !readonly
    end

    def check!
      database.core.check_open!
      transaction&.check_active!
    end

    def writable!
      check!
      raise ReadOnlyError, "view is read-only" if @readonly || !transaction
    end

    def read_bound
      check!
      transaction ? transaction.length : @bound
    end

    def cursor(slot)
      check!
      if transaction
        transaction.cursor(slot: slot)
      else
        Core::Cursor.new(database: database.core, slot: slot, bound: read_bound)
      end
    end

    def resolve(path)
      check!
      slot = root
      path.each_with_index do |selector, index|
        slot = profile.container(slot, context: self, path: path.first(index)).lookup(selector)
        raise ExpiredViewError, "view location no longer exists" unless slot
      end
      slot
    end

    def view(slot, path:, kind:)
      klass = {map: Views::Map, sorted_map: Views::SortedMap, array: Views::Array,
               linked_array: Views::LinkedArray, set: Views::Set, sorted_set: Views::SortedSet}.fetch(kind)
      klass.new(context: self, path: path, kind: kind)
    end

    def changed?
      @changed
    end

    # Publish the logical root only after the complete operation succeeds.
    def mutate(path)
      writable!
      checkpoint = transaction.checkpoint
      completed = false
      begin
        ancestors = []
        slot = root
        path.each_with_index do |selector, index|
          adapter = profile.container(slot, context: self, path: path.first(index))
          ancestors << [adapter, selector]
          slot = adapter.lookup(selector)
          raise ExpiredViewError, "view location no longer exists" unless slot
        end
        target = cursor(slot)
        result = yield target
        if target.slot == slot
          completed = true
          return result
        end
        slot = target.slot
        ancestors.reverse_each do |adapter, selector|
          adapter.assign(selector, slot)
          slot = adapter.slot
        end
        @root = slot
        @changed = true
        completed = true
        result
      ensure
        completed ? transaction.release_checkpoint(checkpoint) : transaction.restore(checkpoint)
      end
    end

    def observe(path)
      check!
      return unless @locations

      location = Location.new(path_key(path), 0, false)
      @locations[location] = true
      location
    end

    def replace_location(path)
      each_location(path) { |location| location.expired = true }
    end

    def invalidate_positions(path, start)
      each_location(path) do |location|
        index = location.path[path.size]
        location.expired = true if index.is_a?(Integer) && index >= start
      end
    end

    def change_membership(path)
      each_location(path) { |location| location.membership += 1 if location.path.size == path.size }
    end

    def invalidate_children(path)
      each_location(path) { |location| location.expired = true if location.path.size > path.size }
    end

    private

    def each_location(path)
      key = path_key(path)
      retained = ObjectSpace::WeakMap.new
      @locations.each_key do |location|
        next if location.expired

        yield location if location.path.first(key.size) == key
        retained[location] = true unless location.expired
      end
      @locations = retained
    end

    def path_key(path)
      path.map { |selector| selector.is_a?(Integer) ? selector : profile.key_bytes(selector) }
    end
  end
end
