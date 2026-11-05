# frozen_string_literal: true

require "securerandom"
require_relative "compaction"
require_relative "replication"

module XitDB
  module Core
    class Database
      include Replication

      ROOT_OFFSET = 20
      DATA_OFFSET = 37
      TRAILER_SIZE = 25
      MINIMUM_SIZE = 62

      attr_reader :header

      def self.open(path, readonly: false, **options)
        store = FileStore.open(path, readonly: readonly)
        begin
          database = new(store: store, **options)
        rescue Exception
          store.send(:close_unreturned)
          raise
        end
        return database unless block_given?

        begin
          yield database
        ensure
          database.close
        end
      end

      def self.memory(hash_size: 20, hash_id: "sha1", file_id: nil)
        new(store: MemoryStore.new, hash_size: hash_size, hash_id: hash_id, file_id: file_id)
      end

      def self.copy_replica(to:, source_io:, length:)
        Replication.copy_replica(to: to, source_io: source_io, length: length)
      end

      def initialize(store:, hash_size: nil, hash_id: nil, file_id: nil, lock_timeout: 5.0, initialize_empty: true, require_empty: false)
        @store = store
        @lock_timeout = lock_timeout
        @needs_reopen = false
        @transaction = nil
        initialize_file = lambda do
          raise ArgumentError, "compaction target must be empty" if require_empty && !store.length.zero?

          if store.length.zero?
            raise CorruptionError, "empty read-only database" if store.readonly?
            raise CorruptionError, "existing empty database" unless initialize_empty

            @header = Header.new(hash_size: hash_size || 20, hash_id: hash_id || "sha1", file_id: file_id || random_id)
            begin
              store.write_at(0, @header.to_bytes + "\0".b * 17)
              publish(Slot.new, 0)
            rescue Exception
              # The exclusive initialization lock still owns this empty target.
              if require_empty && !@needs_reopen
                begin
                  store.truncate(0)
                rescue Exception
                  nil
                end
              end
              raise
            end
          else
            @header = Header.parse(store.read_at(0, Header::SIZE))
            {hash_size: hash_size, hash_id: hash_id, file_id: file_id}.each do |name, value|
              if !value.nil? && value != @header.public_send(name)
                raise ProfileMismatchError, "#{name} does not match the database header"
              end
            end
            committed_state
          end
        end
        if store.readonly?
          initialize_file.call
        else
          store.with_exclusive_lock(timeout: lock_timeout, &initialize_file)
        end
      rescue EOFError => error
        raise CorruptionError, error.message
      end

      def close
        @store.close
      end

      def closed?
        @store.closed?
      end

      def with_operation(&block)
        @store.with_operation(&block)
      end

      def storage_identity
        check_open!
        @store.storage_identity
      end

      def needs_reopen?
        @needs_reopen
      end

      def check_open!
        raise ClosedError, "database is closed" if closed?
      end

      def committed_size
        committed_state.first
      end

      def compact(to:)
        with_operation do
          source = root_cursor
          slot = source.slot
          history = slot.tag == :array_list
          slot = ArrayList.new(source).get(-1) || Slot.new if history
          store = FileStore.open(to)
          begin
            raise ArgumentError, "compaction target is the source file" if store.storage_identity == storage_identity

            file_id = random_id
            file_id = random_id while file_id == header.file_id
            target = Database.new(store: store, hash_id: header.hash_id, hash_size: header.hash_size, file_id: file_id,
                                  lock_timeout: @lock_timeout, require_empty: true)
            offsets = OffsetMap.new
            unless slot.empty?
              target.transaction do |root|
                current = Header.parse(store.read_at(0, Header::SIZE))
                unless current.file_id == file_id && root.bound == MINIMUM_SIZE && root.slot.empty?
                  raise ArgumentError, "compaction target changed before copying"
                end

                copier = Compaction.new(self, source, root.transaction, offsets)
                if history
                  ArrayList.new(root).append(copier.copy(slot))
                else
                  root.replace(copier.copy(slot))
                end
              end
              published = true
            end
            offsets.close
            offsets = nil
            completed = true
            target
          ensure
            unless completed
              begin
                offsets&.close
              rescue Exception
                nil
              end
              target&.send(:restore_empty_target) unless published
              store.send(:close_unreturned)
            end
          end
        end
      end

      def root_cursor
        size, slot = committed_state
        Cursor.new(database: self, slot: slot, bound: size)
      end

      def transaction
        check_open!
        raise TransactionStateError, "database requires reopening" if @needs_reopen

        callback_completed = false
        callback_error = nil
        outcome = :not_committed
        @store.with_exclusive_lock(timeout: @lock_timeout, on_release_error: ->(_error) { @needs_reopen = true }) do
          raise TransactionStateError, "database requires reopening" if @needs_reopen

          size, slot = committed_state
          @store.truncate(size) if @store.length > size
          tx = Transaction.new(self, @store, slot)
          @transaction = tx
          begin
            begin
              yield tx.root
            rescue Exception => error
              callback_error = error
              raise
            end
            callback_completed = true
            unless tx.cancelled?
              publish(tx.root.slot, random_id)
              outcome = :committed
            end
          ensure
            pending_error = $!
            tx.expire!
            @transaction = nil
            # Cleanup must preserve caller exceptions and nonlocal exits.
            if outcome == :not_committed && !@needs_reopen
              begin
                @store.truncate(size)
              rescue Exception => cleanup_error
                @needs_reopen = true
                if callback_completed && pending_error.nil?
                  raise CommitError.new(cleanup_error.message, outcome: :not_committed), cause: cleanup_error
                end
              end
            end
          end
          root_cursor
        end
      rescue Exception => error
        if callback_error && !error.equal?(callback_error)
          @needs_reopen = true
          raise callback_error, cause: callback_error.cause
        end
        raise if error.is_a?(CommitError) || !callback_completed

        @needs_reopen = true
        raise CommitError.new(error.message, outcome: outcome), cause: error
      end

      def bytes(data, format_tag: nil)
        tx = active_transaction
        value = ByteValue.new(data, format_tag: format_tag)
        Bytes.append(tx, size: value.bytes.bytesize, format_tag: value.format_tag) do |position, length|
          value.bytes.byteslice(position, length)
        end
      end

      def read_bytes(slot, bound: nil)
        check_open!
        bound ||= committed_size
        source = Bytes.open(self, slot, bound: bound)
        ByteValue.new(source.read(0, source.size), format_tag: source.format_tag)
      end

      def read_at(offset, size, bound:)
        check_open!
        check_range!(offset, size, bound)
        @store.read_at(offset, size)
      rescue EOFError => error
        raise CorruptionError, error.message
      end

      private

      def close_unreturned
        @store.send(:close_unreturned)
      end

      def restore_empty_target
        return if needs_reopen?

        @store.with_exclusive_lock(timeout: @lock_timeout) do
          current = Header.parse(@store.read_at(0, Header::SIZE))
          next unless current.file_id == header.file_id

          size, slot = committed_state
          @store.truncate(0) if size == MINIMUM_SIZE && slot.empty?
        end
      rescue Exception
        # Cleanup must preserve the original failure or nonlocal exit. A new
        # generation or committed root belongs to its writer and is retained.
        nil
      end

      def active_transaction
        raise TransactionStateError, "allocation requires a transaction" unless @transaction

        @transaction.check_active!
        @transaction
      end

      def check_range!(offset, size, bound)
        unless offset.is_a?(Integer) && size.is_a?(Integer) && bound.is_a?(Integer) &&
               offset >= DATA_OFFSET && size >= 0 && offset + size <= bound
          raise CorruptionError, "object exceeds its read boundary"
        end
      end

      def committed_state
        check_open!
        size = @store.read_at(ROOT_OFFSET + Slot::SIZE, 8).unpack1("Q>")
        raise CorruptionError, "invalid committed file size" if size < MINIMUM_SIZE || size > @store.length

        slot, = Replication.trailer(@store, header, size, size)
        [size, slot]
      rescue EOFError => error
        raise CorruptionError, error.message
      end

      def publish(slot, commit_id)
        outcome = :not_committed
        position = @store.length
        body = slot.to_bytes + [commit_id].pack("Q>")
        checksum = CRC64.call([header.file_id, position].pack("Q>Q>") + body)
        @store.append(body + [checksum].pack("Q>"))
        @store.sync
        outcome = :unknown
        @store.write_at(ROOT_OFFSET, slot.to_bytes + [position + TRAILER_SIZE].pack("Q>"))
        @store.sync
      rescue Exception => error
        @needs_reopen = true if outcome == :unknown
        raise CommitError.new(error.message, outcome: outcome), cause: error
      end

      def random_id
        SecureRandom.random_bytes(8).unpack1("Q>")
      end
    end
  end
end
