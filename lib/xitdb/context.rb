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
      return if transaction

      @reference_proof = reference_proof || database.core.read_at(
        bound - Core::Database::TRAILER_SIZE, Core::Database::TRAILER_SIZE, bound: bound
      ).freeze
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

    def writable_transaction
      check!
      raise ReadOnlyError, "view is read-only" if @readonly

      transaction || raise(ReadOnlyError, "view is read-only")
    end

    def collection(slot, path:)
      profile.container(slot, context: self, path: path) || raise(ExpiredViewError, "view location is not a collection")
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
      unless profile.instance_of?(destination.profile.class) && database.core.header.to_bytes == target.header.to_bytes
        return false
      end
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
        slot = collection(slot, path: path.first(index)).lookup(selector)
        raise ExpiredViewError, "view location no longer exists" unless slot
      end
      slot
    end

    def view(_slot, path:, kind:)
      klass = { map: Views::Map, sorted_map: Views::SortedMap, array: Views::Array,
                linked_array: Views::LinkedArray, set: Views::Set, sorted_set: Views::SortedSet }.fetch(kind)
      klass.new(context: self, path: path, kind: kind)
    end

    def changed?
      @changed
    end

    def copy_from(view, at:, transform: nil)
      writable!
      raise TypeError, "copy source must be a view" unless Object.instance_method(:is_a?).bind_call(view, Views::Base)
      raise TypeError, "copy path must be an Array" unless at.instance_of?(Array)
      raise TypeError, "transform must respond to call" unless transform.nil? || transform.respond_to?(:call)

      read do
        view.context.read do
          source, source_adapter = capture_copy_source(view, at)
          location = copy_location(at)
          parent = location.take([location.size - 1, 0].max)
          present = !location.empty? && !collection(resolve(parent), path: parent).lookup(location.last).nil?
          perform_copy(source, source_adapter, location, parent, transform)
          refresh_copy_location(location, parent, present)
          profile.decode(resolve(location), context: self, path: location)
        end
      end
    end

    # Publish the logical root only after the complete operation succeeds.
    def mutate(path, targets: nil, positions: nil)
      writable!
      transaction = writable_transaction
      transaction.with_logical_mutation do
        check_stream_mutation!(path, targets: targets, positions: positions)
        checkpoint = transaction.checkpoint
        completed = false
        begin
          # @type var ancestors: ::Array[[adapter, selector]]
          ancestors = []
          slot = root
          path.each_with_index do |selector, index|
            adapter = collection(slot, path: path.first(index))
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
      # @type var streams: ::Array[registration]
      streams = @streams ||= []
      if streams.any? { |other, writing| (write || writing) && overlapping_paths?(key, other) }
        raise ConcurrentModificationError, "value has an active byte stream"
      end

      # @type var registration: registration
      registration = [key, write]
      streams << registration
      registration
    end

    def release_stream(registration)
      @streams&.delete_if { |item| item.equal?(registration) }
    end

    def observe(path)
      check!
      locations = @locations
      return unless locations

      location = Location.new(path_key(path), 0, false)
      locations[location] = true
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
      streams = @streams
      return if !streams || streams.empty?

      keys = mutation_keys(path, targets, positions)
      parent = path_key(path) if positions
      conflict = streams.any? do |active, _writing|
        keys.any? { |key| overlapping_paths?(key, active) } ||
          position_conflict?(parent, active, positions)
      end
      raise ConcurrentModificationError, "value has an active byte stream" if conflict
    end

    private

    def mutation_keys(path, targets, positions)
      (targets || (positions ? [] : [path])).map { |target| path_key(target) }
    end

    def capture_copy_source(view, at)
      view.check!
      source_slot = view.slot
      view.context.transaction&.freeze
      source_adapter = view.adapter
      if at.empty? && !%i[map sorted_map].include?(source_adapter.kind)
        raise ProfileMismatchError, "context root must be a map"
      end

      source = Context.new(database: view.context.database, root: source_slot, bound: view.context.read_bound,
                           transaction: view.context.transaction, readonly: true,
                           reference_proof: view.context.reference_proof)
      [source, source_adapter]
    end

    def copy_location(at)
      # @type var location: path
      location = []
      set_kinds = %i[set sorted_set]
      array_kinds = %i[array linked_array]
      at.each_with_index do |selector, index|
        adapter = profile.container(resolve(location), context: self, path: location)
        raise TypeError, "copy parent must be a collection" unless adapter
        raise TypeError, "cannot assign a collection to a set member" if set_kinds.include?(adapter.kind)

        selector = copy_array_position(selector, adapter.size) if array_kinds.include?(adapter.kind)
        adapter.lookup(selector)
        location << case selector
                    when Time then selector.dup.freeze
                    when String then String.new(selector).freeze
                    else selector
                    end
        resolve(location) if index < at.size - 1
      end
      location
    end

    def copy_array_position(selector, size)
      selector = Integer.try_convert(selector) || raise(TypeError, "array position must be an Integer")
      long_max = (1 << (([0].pack("l!").bytesize * 8) - 1)) - 1
      raise RangeError, "array position is too large" unless ((-long_max - 1)..long_max).cover?(selector)

      selector += size if selector.negative?
      raise IndexError, "array index outside list" if selector.negative?
      raise IndexError, "array size too big" if selector + 1 > long_max / 0.size

      selector
    end

    def perform_copy(source, source_adapter, location, parent, transform)
      operation = lambda do
        mutate(location.empty? ? [] : parent, targets: [location]) do |cursor|
          assign_copy(cursor, source, source_adapter, location, parent, transform)
        end
      end
      source_transaction = source.transaction
      if source_transaction && !source_transaction.equal?(transaction)
        source_transaction.with_logical_mutation(&operation)
      else
        operation.call
      end
    end

    def assign_copy(cursor, source, source_adapter, location, parent, transform)
      copied = Conversion.new(source, self, transform: transform).copy(source.root, adapter: source_adapter)
      if location.empty?
        cursor.replace(copied)
      else
        adapter = collection(cursor.slot, path: parent)
        if %i[array linked_array].include?(adapter.kind)
          position = Integer.try_convert(location.last) || raise(TypeError, "array position must be an Integer")
          adapter.assign(adapter.size, Core::Slot.null) while adapter.size < position
        end
        adapter.assign(location.last, copied)
        cursor.replace(adapter.slot)
      end
    end

    def refresh_copy_location(location, parent, present)
      if location.empty?
        invalidate_children([])
        change_membership([])
      else
        replace_location(location)
        change_membership(parent) unless present
      end
    end

    def position_conflict?(parent, active, positions)
      return false unless parent && positions && overlapping_paths?(parent, active)

      active.size <= parent.size || positions.cover?(active[parent.size])
    end

    def overlapping_paths?(left, right)
      left.first(right.size).eql?(right) || right.first(left.size).eql?(left)
    end

    def each_location(path)
      key = path_key(path)
      retained = ObjectSpace::WeakMap.new
      @locations&.each_key do |location|
        next if location.expired

        yield location if location.path.first(key.size).eql?(key)
        retained[location] = true unless location.expired
      end
      @locations = retained
    end

    def path_key(path)
      slot = root
      path.each_with_index.map do |selector, index|
        adapter = collection(slot, path: path.first(index))
        key = if defined?(Ruby::Containers) && adapter.is_a?(Ruby::Containers)
                adapter.selector_identity(selector)
              else
                case selector
                when Integer then selector
                else profile.key_bytes(selector)
                end
              end
        slot = adapter.lookup(selector) if index < path.size - 1
        key
      end
    end
  end
end
