# frozen_string_literal: true

module XitDB
  # Owns one captured root or one transaction's logical root.
  class Context
    Location = Struct.new(:path, :membership, :expired)
    private_constant :Location

    attr_reader :database, :profile, :transaction, :root, :reference_proof

    def initialize(database:, root:, bound:, transaction: nil, readonly: false, reference_proof: nil)
      @database = database
      @profile = database.profile
      @root = root
      @bound = bound
      @transaction = transaction
      @readonly = readonly
      @changed = false
      @locations = ObjectSpace::WeakMap.new if transaction && !readonly
      unless transaction
        @reference_proof = reference_proof || database.core.read_at(
          bound - Core::Database::TRAILER_SIZE, Core::Database::TRAILER_SIZE, bound: bound
        ).freeze
      end
    end

    def check!
      database.core.check_open!
      transaction&.check_active!
    end

    def read
      database.core.with_operation do
        check!
        yield
      end
    end

    def writable!
      check!
      raise ReadOnlyError, "view is read-only" if @readonly || !transaction

      transaction.check_logical_mutation!
    end

    def read_bound
      check!
      transaction ? transaction.length : @bound
    end

    def reference_compatible?(destination)
      check!
      destination.check!
      target = destination.database.core
      return false unless database.core.storage_identity == target.storage_identity
      return false unless profile.class == destination.profile.class && database.core.header.to_bytes == target.header.to_bytes
      return transaction.equal?(destination.transaction) if transaction
      return false if @bound > destination.read_bound

      reference_proof == target.read_at(@bound - Core::Database::TRAILER_SIZE,
                                       Core::Database::TRAILER_SIZE, bound: destination.read_bound)
    rescue CorruptionError
      false
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
    def mutate(path, targets: nil, positions: nil)
      writable!
      transaction.with_logical_mutation do
        check_stream_mutation!(path, targets: targets, positions: positions)
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
    end

    def register_stream(path, write:)
      check!
      key = path_key(path)
      @streams ||= []
      if @streams.any? { |other, writing| (write || writing) && overlapping_paths?(key, other) }
        raise ConcurrentModificationError, "value has an active byte stream"
      end

      registration = [key, write]
      @streams << registration
      registration
    end

    def release_stream(registration)
      @streams&.delete_if { |item| item.equal?(registration) }
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

    def check_stream_mutation!(path, targets: nil, positions: nil)
      return if !@streams || @streams.empty?

      keys = (targets || (positions ? [] : [path])).map { |target| path_key(target) }
      parent = path_key(path) if positions
      conflict = @streams.any? do |active, _writing|
        keys.any? { |key| overlapping_paths?(key, active) } ||
          (parent && overlapping_paths?(parent, active) &&
            (active.size <= parent.size || positions.cover?(active[parent.size])))
      end
      raise ConcurrentModificationError, "value has an active byte stream" if conflict
    end

    private

    def overlapping_paths?(left, right)
      left.first(right.size).eql?(right) || right.first(left.size).eql?(left)
    end

    def each_location(path)
      key = path_key(path)
      retained = ObjectSpace::WeakMap.new
      @locations.each_key do |location|
        next if location.expired

        yield location if location.path.first(key.size).eql?(key)
        retained[location] = true unless location.expired
      end
      @locations = retained
    end

    def path_key(path)
      slot = root
      path.each_with_index.map do |selector, index|
        adapter = profile.container(slot, context: self, path: path.first(index))
        key = if adapter.respond_to?(:selector_identity)
          adapter.selector_identity(selector)
        else
          Integer === selector ? selector : profile.key_bytes(selector)
        end
        slot = adapter.lookup(selector) if index < path.size - 1
        key
      end
    end
  end
end
