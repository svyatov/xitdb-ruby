# frozen_string_literal: true

module XitDB
  # Owns one captured root or one transaction's logical root.
  #
  # A path is a sequence of map keys or array positions from the root.
  # Views share this context so they agree on lifetime, writes, and stream locks.
  # The explicit copy operation is available through a view's context.
  #
  # @see #copy_from
  class Context
    # A weakly retained observation of a view's path and membership generation.
    Location = Struct.new(:path, :membership, :expired)
    private_constant :Location

    # @!attribute [r] database
    #   Handle that owns this context's storage.
    #   @return [Database]
    # @!attribute [r] profile
    #   Rules for interpreting this context's values.
    #   @return [Profiles::Portable, Profiles::Ruby]
    # @!attribute [r] transaction
    #   Writer whose lifetime this context shares, or nil for snapshots.
    #   @return [Core::Transaction, nil]
    # @!attribute [r] root
    #   Stored logical root, updated only after a successful mutation.
    #   @return [Core::Slot]
    # @!attribute [r] reference_proof
    #   Captured trailer bytes used to validate safe reference sharing.
    #   @return [String, nil]
    attr_reader :database, :profile, :transaction, :root, :reference_proof

    # Capture the root, readable byte boundary, and optional transaction for a family of views.
    # @param database [Database]
    # @param root [Core::Slot] logical root
    # @param bound [Integer] exclusive byte boundary of the captured commit
    # @param transaction [Core::Transaction, nil] active writer, or nil for a snapshot
    # @param readonly [Boolean] forbid writes even when a transaction exists
    # @param reference_proof [String, nil] captured trailer bytes proving the file generation
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

    # Require an open database and, for writable views, an active transaction.
    # @return [void]
    def check!
      database.core.check_open!
      transaction&.check_active!
    end

    # Keep storage open for one read operation and validate this context.
    # @yield perform the read
    # @return [Object] block result
    def read
      database.core.with_operation do
        check!
        yield
      end
    end

    # Require a writable context and permit entry into a logical mutation.
    # @return [void]
    # @raise [ReadOnlyError] if this context is read-only
    def writable!
      check!
      raise ReadOnlyError, "view is read-only" if @readonly || !transaction

      transaction.check_logical_mutation!
    end

    # Retrieve the active writer after checking context lifetime and permissions.
    # @return [Core::Transaction]
    # @raise [ReadOnlyError] if no writable transaction exists
    def writable_transaction!
      check!
      raise ReadOnlyError, "view is read-only" if @readonly

      transaction || raise(ReadOnlyError, "view is read-only")
    end

    # Interpret a slot as a collection under the selected profile.
    # @param slot [Core::Slot]
    # @param path [Array<Object>] diagnostic and view location
    # @return [Profiles::Portable::Adapter, Ruby::Containers]
    # @raise [ExpiredViewError] if the slot no longer names a collection
    def collection(slot, path:)
      profile.container(slot, context: self, path: path) || raise(ExpiredViewError, "view location is not a collection")
    end

    # Return the exclusive byte boundary this context may read.
    # @return [Integer] transaction length or captured commit boundary
    def read_bound
      check!
      transaction ? transaction.length : @bound
    end

    # Check whether a destination can safely reuse this context's stored references.
    #
    # Matching paths alone are insufficient. Storage identity, profile, header, and
    # commit proof must agree; transaction references require the same transaction.
    # @param destination [Context]
    # @return [Boolean]
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

    # Create a storage cursor with this context's lifetime and readable boundary.
    # @param slot [Core::Slot]
    # @return [Core::Cursor]
    def cursor(slot)
      check!
      if transaction
        transaction.cursor(slot: slot)
      else
        Core::Cursor.new(database: database.core, slot: slot, bound: read_bound)
      end
    end

    # Follow selectors from the logical root to a stored slot.
    # @param path [Array<Object>]
    # @return [Core::Slot]
    # @raise [ExpiredViewError] if any selected location is absent
    def resolve(path)
      check!
      slot = root
      path.each_with_index do |selector, index|
        slot = collection(slot, path: path.first(index)).lookup(selector)
        raise ExpiredViewError, "view location no longer exists" unless slot
      end
      slot
    end

    # Bind a public view to a snapshot reference or live transaction location.
    # @param slot [Core::Slot] resolved value; snapshot views retain this immutable reference
    # @param path [Array<Object>]
    # @param kind [Symbol] logical collection kind
    # @return [Views::Base]
    def view(slot, path:, kind:)
      klass = { map: Views::Map, sorted_map: Views::SortedMap, array: Views::Array,
                linked_array: Views::LinkedArray, set: Views::Set, sorted_set: Views::SortedSet }.fetch(kind)
      klass.new(context: self, path: path, kind: kind, slot: slot)
    end

    # Report whether a successful mutation published a different logical root.
    # @return [Boolean]
    def changed?
      @changed
    end

    # Copy a view into this transaction, including across files or profiles.
    #
    # Assignment can share compatible references. This operation explicitly copies
    # logical contents and can transform unsupported values and keys.
    # @param view [Views::Base] source collection
    # @param at [Array<Object>] destination selectors; an empty path replaces the root
    # @param transform [#call, nil] callback receiving value:, path:, and role:
    # @return [Object] destination's decoded value
    # @raise [TypeError] if the source, path, or transform is invalid
    # @raise [KeyCollisionError] if transformed keys collide
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
    # Change a collection and rebuild ancestor references only after success.
    #
    # A checkpoint records temporary writes. Failure restores that checkpoint,
    # so a partially encoded value cannot become the context's root.
    # @param path [Array<Object>] collection location
    # @param targets [Array<Array<Object>>, nil] exact affected entry paths
    # @param positions [Range, nil] affected array positions
    # @yield [cursor] change the selected storage slot
    # @yieldparam cursor [Core::Cursor]
    # @return [Object] block result
    # @raise [ConcurrentModificationError] if the change overlaps an active stream
    def mutate(path, targets: nil, positions: nil)
      writable!
      transaction = writable_transaction!
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

    # Reserve a byte location while a reader or writer block is active.
    # @param path [Array<Object>]
    # @param write [Boolean] whether this stream writes
    # @return [Array] registration token for release_stream
    # @raise [ConcurrentModificationError] if an overlapping stream includes a writer
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

    # Release the exact reservation token when a stream block ends.
    # @param registration [Array]
    # @return [void]
    def release_stream(registration)
      @streams&.delete_if { |item| item.equal?(registration) }
    end

    # Track a transaction view's location without keeping the view alive.
    # @param path [Array<Object>]
    # @return [Location, nil] nil for a snapshot context
    def observe(path)
      check!
      locations = @locations
      return unless locations

      location = Location.new(path_key(path), 0, false)
      locations[location] = true
      location
    end

    # Expire observed views at or below a replaced location.
    # @param path [Array<Object>]
    # @return [void]
    def replace_location(path)
      each_location(path) { |location| location.expired = true }
    end

    # Expire child array views whose positions can have shifted.
    # @param path [Array<Object>] parent collection
    # @param start [Integer] first affected position
    # @return [void]
    def invalidate_positions(path, start)
      each_location(path) do |location|
        index = location.path[path.size]
        location.expired = true if index.is_a?(Integer) && index >= start
      end
    end

    # Advance the generation checked by iterators at this collection.
    # @param path [Array<Object>]
    # @return [void]
    def change_membership(path)
      each_location(path) { |location| location.membership += 1 if location.path.size == path.size }
    end

    # Expire descendants while retaining a view of the collection itself.
    # @param path [Array<Object>]
    # @return [void]
    def invalidate_children(path)
      each_location(path) { |location| location.expired = true if location.path.size > path.size }
    end

    # Reject a mutation whose paths or shifted positions affect an active byte stream.
    # @param path [Array<Object>]
    # @param targets [Array<Array<Object>>, nil]
    # @param positions [Range, nil]
    # @return [void]
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

    # Translate exact mutation targets into profile-aware identity paths.
    # @return [Array<Array<Object>>]
    def mutation_keys(path, targets, positions)
      (targets || (positions ? [] : [path])).map { |target| path_key(target) }
    end

    # Freeze the source structure and require a map when replacing the root.
    # @return [Array(Context, Object)] source context and adapter
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

    # Validate destination selectors and own mutable key values before copying.
    # @return [Array<Object>] normalized destination path
    def copy_location(at)
      # @type var location: path
      location = []
      set_kinds = %i[set sorted_set]
      array_kinds = %i[array linked_array]
      at.each_with_index do |selector, index|
        adapter = profile.container(resolve(location), context: self, path: location)
        raise TypeError, "copy parent must be a collection" unless adapter
        raise TypeError, "cannot assign a collection to a set member" if set_kinds.include?(adapter.kind)

        selector = copy_array_position!(selector, adapter.size) if array_kinds.include?(adapter.kind)
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

    # Normalize a copy position and validate native array growth bounds.
    # @return [Integer]
    def copy_array_position!(selector, size)
      selector = Integer.try_convert(selector) || raise(TypeError, "array position must be an Integer")
      long_max = (1 << (([0].pack("l!").bytesize * 8) - 1)) - 1
      raise RangeError, "array position is too large" unless ((-long_max - 1)..long_max).cover?(selector)

      selector += size if selector.negative?
      raise IndexError, "array index outside list" if selector.negative?
      raise IndexError, "array size too big" if selector + 1 > long_max / 0.size

      selector
    end

    # Guard both source and destination transactions while performing a logical copy.
    # @return [void]
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

    # Encode copied contents and replace the root or selected child entry.
    # @return [void]
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

    # Expire replaced views and update membership after a successful copy.
    # @return [void]
    def refresh_copy_location(location, parent, present)
      if location.empty?
        invalidate_children([])
        change_membership([])
      else
        replace_location(location)
        change_membership(parent) unless present
      end
    end

    # Test whether an active stream uses an affected array position or ancestor.
    # @return [Boolean]
    def position_conflict?(parent, active, positions)
      return false unless parent && positions && overlapping_paths?(parent, active)

      active.size <= parent.size || positions.cover?(active[parent.size])
    end

    # Test whether either identity path is a prefix of the other.
    # @return [Boolean]
    def overlapping_paths?(left, right)
      left.first(right.size).eql?(right) || right.first(left.size).eql?(left)
    end

    # Visit live descendant observations and discard expired weak references.
    # @yield [location]
    # @yieldparam location [Location]
    # @return [void]
    def each_location(path)
      # @type var key: path?
      key = nil
      retained = ObjectSpace::WeakMap.new
      @locations&.each_key do |location|
        next if location.expired

        if location.path.size >= path.size
          matched_key = key || path_key(path)
          key = matched_key
          yield location if location.path.first(matched_key.size).eql?(matched_key)
        end
        retained[location] = true unless location.expired
      end
      @locations = retained
    end

    # Represent each selector using its parent collection's key identity rules.
    # @return [Array<Object>]
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
