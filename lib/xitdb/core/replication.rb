# frozen_string_literal: true

module XitDB
  module Core
    ReplicaState = Data.define(:committed_size, :checksum)

    module Replication
      CHUNK_SIZE = 64 * 1024

      def replica_state
        with_operation do
          size, = committed_state
          _, checksum = Replication.trailer(@store, header, size, size)
          ReplicaState.new(committed_size: size, checksum: checksum)
        end
      end

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

      def apply_replicated(start, io, length)
        Replication.position(start)
        Replication.position(length)
        raise ArgumentError, "full replacement requires Database.copy_replica" if start.zero?
        raise TransactionStateError, "database requires reopening" if @needs_reopen

        outcome = :not_committed
        completed = false
        @store.with_exclusive_lock(timeout: @lock_timeout, on_release_error: ->(_error) { @needs_reopen = true }) do
          raise TransactionStateError, "database requires reopening" if @needs_reopen

          size, = committed_state
          raise ArgumentError, "replication start must equal committed size" unless start == size

          begin
            Replication.storage_write { @store.truncate(size) } if @store.length > size
            Replication.read_chunks(io, length) do |chunk|
              Replication.storage_write { @store.append(chunk) }
            end
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
            @needs_reopen = true if outcome == :unknown
            if !completed && outcome == :not_committed
              begin
                @store.truncate(size)
              rescue Exception
                @needs_reopen = true
              end
            end
          end
        end
        nil
      rescue Exception => error
        # A release failure after successful application cannot undo durability.
        if completed && !error.is_a?(CommitError)
          raise CommitError.new(error.message, outcome: outcome), cause: error
        end
        raise
      end

      def self.copy_replica(to:, source_io:, length:)
        position(length)
        raise ArgumentError, "full replica is shorter than a database" if length < Database::MINIMUM_SIZE

        store = FileStore.open(to)
        outcome = :not_committed
        completed = false
        begin
          store.with_exclusive_lock do
            raise ArgumentError, "replica staging target must be empty" unless store.length.zero?

            begin
              read_chunks(source_io, length) { |chunk| storage_write { store.append(chunk) } }
              header = Header.parse(store.read_at(0, Header::SIZE))
              root = store.read_at(Database::ROOT_OFFSET, 17)
              unless root.byteslice(9, 8).unpack1("Q>") == length
                raise CorruptionError, "full replica length does not match its root header"
              end
              slot, = trailer(store, header, length, length)
              raise CorruptionError, "full replica root does not match its trailer" unless root.byteslice(0, 9) == slot.to_bytes

              outcome = :unknown
              storage_write(outcome: outcome) { store.sync }
              outcome = :committed
              completed = true
            ensure
              if !completed && outcome == :not_committed
                begin
                  store.truncate(0)
                rescue Exception
                  nil
                end
              end
            end
          end
          database = Database.new(store: store, initialize_empty: false)
          returned = true
          database
        rescue Exception => error
          if completed && !error.is_a?(CommitError)
            raise CommitError.new(error.message, outcome: outcome), cause: error
          end
          raise
        ensure
          unless returned
            begin
              store.close
            rescue Exception
              # This unreturned staging store has no caller that can retry close.
              # Retain physical output while releasing its private descriptor.
              begin
                store.close(discard: true)
              rescue Exception
                nil
              end
            end
          end
        end
      end

      def self.position(value)
        raise TypeError, "offset and length must be Integers" unless value.is_a?(Integer)
        raise ArgumentError, "offset and length must be nonnegative" if value.negative?
      end

      def self.trailer(store, header, finish, bound)
        unless finish >= Database::MINIMUM_SIZE && finish <= bound
          raise CorruptionError, "invalid root trailer position"
        end

        position = finish - Database::TRAILER_SIZE
        bytes = store.read_at(position, Database::TRAILER_SIZE)
        slot = Slot.parse(bytes.byteslice(0, 9))
        raise CorruptionError, "unknown root slot tag" unless Slot::TAGS.include?(slot.tag)

        checksum = bytes.byteslice(17, 8).unpack1("Q>")
        expected = CRC64.call([header.file_id, position].pack("Q>Q>") + bytes.byteslice(0, 17))
        raise CorruptionError, "invalid root trailer checksum" unless checksum == expected

        [slot, checksum]
      rescue EOFError => error
        raise CorruptionError, error.message
      end

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

      def self.write_all(io, bytes)
        offset = 0
        while offset < bytes.bytesize
          count = io.write(bytes.byteslice(offset..))
          unless count.is_a?(Integer) && count.positive? && count <= bytes.bytesize - offset
            raise IOError, "replication writer made invalid progress"
          end

          offset += count
        end
      end

      def self.storage_write(outcome: :not_committed)
        yield
      rescue Exception => error
        raise CommitError.new(error.message, outcome: outcome), cause: error
      end
    end
  end
end
