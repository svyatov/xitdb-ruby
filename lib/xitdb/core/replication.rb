# frozen_string_literal: true

module XitDB
  module Core
    # A receiver's committed boundary and root checksum used to select a replication start.
    # @!attribute [r] committed_size
    #   @return [Integer] committed byte boundary
    # @!attribute [r] checksum
    #   @return [Integer] unsigned 64-bit checksum of the committed root trailer
    # A receiver's committed boundary and root checksum used to select a replication start.
    # @!attribute [r] committed_size
    #   @return [Integer] committed byte boundary
    # @!attribute [r] checksum
    #   @return [Integer] unsigned 64-bit checksum of the committed root trailer
    ReplicaState = Data.define(:committed_size, :checksum)

    # Byte-level replication operations included in Core::Database.
    #
    # A replica state identifies a committed boundary and its root checksum.
    #
    # A matching boundary permits an incremental append; otherwise the receiver needs a complete copy.
    module Replication
      # Maximum bytes requested or emitted per replication chunk.
      CHUNK_SIZE = 64 * 1024

      # Captures the committed byte count and root checksum for replication negotiation.
      # @return [ReplicaState]
      def replica_state
        with_operation do
          size, = committed_state
          _, checksum = Replication.trailer(@store, header, size, size)
          ReplicaState.new(committed_size: size, checksum: checksum)
        end
      end

      # Returns the matching committed boundary, or zero when a full copy is required.
      # @param state [ReplicaState] receiver committed boundary and checksum
      # @return [Integer]
      # @note Matching uses the root trailer checksum at the supplied boundary.
      # @raise [TypeError] if state is not a ReplicaState
      def replication_start(state)
        raise TypeError, "expected ReplicaState" unless state.is_a?(ReplicaState)

        Replication.position(state.committed_size)
        Format.integer(state.checksum, 0..Format::UINT64_MAX)
        with_operation do
          size, = committed_state
          next 0 if state.committed_size > size || state.committed_size < Database::MINIMUM_SIZE

          begin
            _, checksum = Replication.trailer(@store, header, state.committed_size, size)
            checksum == state.checksum ? state.committed_size : 0
          rescue CorruptionError
            0
          end
        end
      end

      # Writes a committed byte range to an IO-like destination.
      # @param start [Integer] absolute starting byte offset of the transfer
      # @param finish [Integer] exclusive end offset of the committed range
      # @param io [#write] binary destination implementing write(bytes)
      # @return [nil]
      # @note A zero start writes a complete header with root metadata for finish.
      # @raise [ArgumentError] if the byte range is invalid or exceeds committed data
      # @raise [IOError] if the destination reports an invalid write count
      def read_committed(start, finish, io)
        Replication.position(start)
        Replication.position(finish)
        with_operation do
          size, = committed_state
          if start > finish || finish > size || (start.positive? && start < Database::DATA_OFFSET)
            raise ArgumentError, "invalid committed byte range"
          end

          if start.zero?
            slot, = Replication.trailer(@store, header, finish, size)
            Replication.write_all(io, @store.read_at(0, Header::SIZE))
            Replication.write_all(io, slot.to_bytes + [finish].pack("Q>"))
            start = Database::DATA_OFFSET
          end
          while start < finish
            chunk = @store.read_at(start, [finish - start, CHUNK_SIZE].min)
            Replication.write_all(io, chunk)
            start += chunk.bytesize
          end
        end
        nil
      end

      # Appends a replication range and publishes its validated final root.
      # @param start [Integer] absolute starting byte offset of the transfer
      # @param io [#read] binary source implementing read(length)
      # @param length [Integer] number of bytes
      # @return [nil]
      # @raise [ArgumentError] if start is zero or differs from the current committed size
      # @raise [EOFError] if the stream ends before length bytes
      # @raise [CommitError] if storage fails; its outcome describes possible publication
      # @raise [TransactionStateError] if this handle requires reopening
      def apply_replicated(start, io, length)
        Replication.position(start)
        Replication.position(length)
        raise ArgumentError, "full replacement requires Database.copy_replica" if start.zero?
        raise TransactionStateError, "database requires reopening" if @needs_reopen

        # @type var outcome: :not_committed | :committed | :unknown
        outcome = :not_committed
        completed = false
        @store.with_exclusive_lock(timeout: @lock_timeout, on_release_error: ->(_error) { @needs_reopen = true }) do
          raise TransactionStateError, "database requires reopening" if @needs_reopen

          size, = committed_state
          raise ArgumentError, "replication start must equal committed size" unless start == size

          begin
            append_replica_chunks(io, length, size)
            if length.positive?
              finish = start + length
              slot, = Replication.trailer(@store, header, finish, finish)
              Replication.storage_write { @store.sync }
              outcome = :unknown
              Replication.storage_write(outcome: outcome) do
                @store.write_at(Database::ROOT_OFFSET, slot.to_bytes + [finish].pack("Q>"))
                @store.sync
              end
              outcome = :committed
            end
            completed = true
          ensure
            recover_replica_application(size, completed, outcome)
          end
        end
        nil
      rescue Exception => e # rubocop:disable Lint/RescueException -- Preserve durability reporting for interrupts and fatal errors.
        # A release failure after successful application cannot undo durability.
        if completed && !e.is_a?(CommitError)
          raise CommitError.new(e.message, outcome: outcome || :not_committed), cause: e
        end

        raise
      end

      # Removes stale uncommitted bytes and appends declared replication chunks.
      def append_replica_chunks(io, length, size)
        Replication.storage_write { @store.truncate(size) } if @store.length > size
        Replication.read_chunks(io, length) do |chunk|
          Replication.storage_write { @store.append(chunk) }
        end
      end

      # Rolls back an unpublished append or marks uncertain publication for reopening.
      def recover_replica_application(size, completed, outcome)
        @needs_reopen = true if outcome == :unknown
        return if completed || outcome != :not_committed

        begin
          @store.truncate(size)
        rescue Exception # rubocop:disable Lint/RescueException -- Rollback failure requires reopening even after an interrupt.
          @needs_reopen = true
        end
      end
      private :append_replica_chunks, :recover_replica_application

      # Stages and validates a complete replica in an empty destination file.
      # @param to [String] destination file path, which must be empty or absent
      # @param source_io [#read] binary reader implementing read(length)
      # @param length [Integer] number of bytes
      # @return [Database]
      # @raise [ArgumentError] if the target is nonempty or the replica is shorter than a database
      # @raise [CorruptionError] if root metadata or the checksum is invalid
      # @raise [EOFError] if the stream ends before length bytes
      # @raise [CommitError] if durable staging or cleanup fails
      def self.copy_replica(to:, source_io:, length:)
        position(length)
        raise ArgumentError, "full replica is shorter than a database" if length < Database::MINIMUM_SIZE

        store = FileStore.open(to)
        # @type var outcome: :not_committed | :committed | :unknown
        outcome = :not_committed
        completed = false
        begin
          store.with_exclusive_lock do
            # FileStore measures bytes and has no collection #empty? method.
            unless store.length.zero? # rubocop:disable Style/ZeroLengthPredicate
              raise ArgumentError, "replica staging target must be empty"
            end

            begin
              read_chunks(source_io, length) { |chunk| storage_write { store.append(chunk) } }
              validate_replica(store, length)

              outcome = :unknown
              storage_write(outcome: outcome) { store.sync }
              outcome = :committed
              completed = true
            ensure
              cleanup_staged_replica(store, completed, outcome)
            end
          end
          database = Database.new(store: store, initialize_empty: false)
          returned = true
          database
        rescue Exception => e # rubocop:disable Lint/RescueException -- Report durable commits even when cleanup is interrupted.
          raise CommitError.new(e.message, outcome: outcome), cause: e if completed && !e.is_a?(CommitError)

          raise
        ensure
          store.send(:close_unreturned) unless returned
        end
      end

      # Removes staged bytes only when durable publication has not started.
      def self.cleanup_staged_replica(store, completed, outcome)
        return if completed || outcome != :not_committed

        begin
          store.truncate(0)
        rescue Exception # rubocop:disable Lint/RescueException -- Preserve the original failure if staging cleanup fails.
          nil
        end
      end
      private_class_method :cleanup_staged_replica

      # Checks the declared size and matching root header and trailer.
      def self.validate_replica(store, length)
        header = Header.parse(store.read_at(0, Header::SIZE))
        root = store.read_at(Database::ROOT_OFFSET, 17)
        unless Format.unsigned(Format.slice(root, 9, 8)) == length
          raise CorruptionError, "full replica length does not match its root header"
        end

        slot, = trailer(store, header, length, length)
        return if root.byteslice(0, 9) == slot.to_bytes

        raise CorruptionError, "full replica root does not match its trailer"
      end
      private_class_method :validate_replica

      # Rejects offsets and lengths that are not nonnegative integers.
      # @param value [Integer] integer value
      # @return [void]
      def self.position(value)
        raise TypeError, "offset and length must be Integers" unless value.is_a?(Integer)
        raise ArgumentError, "offset and length must be nonnegative" if value.negative?
      end

      # Validates a committed trailer's location, slot tag, and checksum.
      # @param store [MemoryStore, FileStore] underlying byte storage
      # @param header [Header] file header containing the checksum identity
      # @param finish [Integer] exclusive end offset of the committed range
      # @param bound [Integer] exclusive upper byte boundary for reads
      # @return [Array(Slot, Integer)]
      # @raise [CorruptionError] if the boundary, slot tag, or checksum is invalid
      def self.trailer(store, header, finish, bound)
        raise CorruptionError, "invalid root trailer position" unless finish.between?(Database::MINIMUM_SIZE, bound)

        position = finish - Database::TRAILER_SIZE
        bytes = store.read_at(position, Database::TRAILER_SIZE)
        slot = Slot.parse(Format.slice(bytes, 0, 9))
        raise CorruptionError, "unknown root slot tag" unless Slot::TAGS.include?(slot.tag)

        checksum = Format.unsigned(Format.slice(bytes, 17, 8))
        expected = CRC64.call([header.file_id, position].pack("Q>Q>") + Format.slice(bytes, 0, 17))
        raise CorruptionError, "invalid root trailer checksum" unless checksum == expected

        [slot, checksum]
      rescue EOFError => e
        raise CorruptionError, e.message
      end

      # Reads exactly the declared number of bytes, yielding bounded chunks.
      # @param io [#read] binary source implementing read(length)
      # @param length [Integer] number of bytes
      # @return [void]
      # @yield [bytes] consumes each chunk before reading the next
      # @yieldparam bytes [String] at most CHUNK_SIZE bytes
      # @yieldreturn [Object] ignored
      # @raise [EOFError] if the stream ends early
      # @raise [IOError] if the reader returns an invalid chunk
      def self.read_chunks(io, length)
        while length.positive?
          count = [length, CHUNK_SIZE].min
          bytes = io.read(count)
          raise EOFError, "replication stream ended before its declared length" if bytes.nil? || bytes == ""
          unless bytes.is_a?(String) && bytes.bytesize <= count
            raise IOError, "replication reader returned an invalid chunk"
          end

          yield bytes
          length -= bytes.bytesize
        end
      end

      # Repeats writes until the destination accepts every byte.
      # @param io [#write] binary destination implementing write(bytes)
      # @param bytes [String] binary input bytes
      # @return [void]
      def self.write_all(io, bytes)
        offset = 0
        while offset < bytes.bytesize
          count = io.write(Format.slice(bytes, offset..))
          unless count.is_a?(Integer) && count.positive? && count <= bytes.bytesize - offset
            raise IOError, "replication writer made invalid progress"
          end

          offset += count
        end
      end

      # Adds the known commit outcome to a storage failure.
      # @param outcome [Symbol] :not_committed, :committed, or :unknown durability outcome
      # @return [Object]
      # @yield performs the storage operation
      # @yieldreturn [Object] result returned to the caller
      # @raise [CommitError] wraps any storage exception with the supplied outcome
      def self.storage_write(outcome: :not_committed)
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException -- Every storage failure must retain its commit outcome.
        raise CommitError.new(e.message, outcome: outcome), cause: e
      end
    end
  end
end
