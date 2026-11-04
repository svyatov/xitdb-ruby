# frozen_string_literal: true

module XitDB
  # Owns one captured root or one transaction's logical root.
  class Context
    attr_reader :database, :profile, :transaction, :root

    def initialize(database:, root:, bound:, transaction: nil, readonly: false)
      @database = database
      @profile = database.profile
      @root = root
      @bound = bound
      @transaction = transaction
      @readonly = readonly
      @changed = false
      @replacements = Hash.new(0)
      @children = Hash.new(0)
      @memberships = Hash.new(0)
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

    def generations(path)
      check!
      (0..path.size).flat_map do |length|
        key = path_key(path.first(length))
        [@replacements[key], length < path.size ? @children[key] : 0]
      end
    end

    def replace_location(path)
      @replacements[path_key(path)] += 1
    end

    def membership(path)
      @memberships[path_key(path)]
    end

    def change_membership(path)
      @memberships[path_key(path)] += 1
    end

    def invalidate_children(path)
      @children[path_key(path)] += 1
    end

    private

    def path_key(path)
      path.map { |selector| selector.is_a?(Integer) ? selector : profile.key_bytes(selector) }
    end
  end
end
