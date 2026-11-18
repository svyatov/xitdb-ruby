# frozen_string_literal: true

require_relative "../core"
require_relative "budget"

module XitDB
  # Readers used by the read-only structural verifier.
  # @api private
  module Verification
    # One captured committed boundary and its latest history entry.
    class Scan
      CHUNK_SIZE = 65_536
      attr_reader :bound, :header, :profile, :root, :root_offset, :budget, :history_offsets

      def self.open(path, limits: {})
        store = Core::FileStore.open(path, readonly: true)
        begin
          yield new(store, Budget.new(limits))
        ensure
          store.close
        end
      end

      def initialize(store, budget)
        @store = store
        @budget = budget
        @codec_ids = {}
        @header = checked(:header, 0) { Core::Header.parse(store.read_at(0, Core::Header::SIZE)) }
        @profile = select_profile
        @bound = checked(:committed_size, header.committed_size_offset) { Core::Replication.committed_size(store, header) }
        trailer = bound - Core::Database::TRAILER_SIZE
        history = checked(:trailer, trailer) { Core::Replication.trailer(store, header, bound, bound).first }
        @root_offset = trailer
        @history_offsets = []
        @root = latest(history)
        @history_offsets.freeze
      rescue FormatVersionError => e
        raise if e.is_a?(UnsupportedVerificationFormatError)

        raise UnsupportedVerificationFormatError, e.message
      end

      def read(offset, length)
        unless offset >= header.data_offset && length >= 0 && offset + length <= bound
          raise VerificationError.new("read outside committed storage", check: :extent, offset: offset)
        end
        raise VerificationLimitError, :read_bytes if length > CHUNK_SIZE

        checked(:extent, offset) { @store.read_at(offset, length) }
      end

      def codec_ids
        @codec_ids.keys.freeze
      end

      def register_codec!(id)
        return if @codec_ids.key?(id)

        # Include space for the retained string, hash entry and result array slot.
        budget.reserve!(:codec_bytes, id.bytesize + 96)
        @codec_ids[id.freeze] = true
      end

      private

      def checked(check, offset)
        yield
      rescue CorruptionError, EOFError => e
        raise VerificationError.new(e.message, check: check, offset: offset)
      end

      def select_profile
        return :ruby if header.hash_id == "rb05" && header.hash_size == 32

        Core::Hasher.for_header(header)
        :portable
      rescue ProfileMismatchError => e
        raise UnsupportedVerificationFormatError, e.message
      end

      def latest(history)
        return if history == Core::Slot.new

        unless history.tag == :array_list && !history.full?
          raise VerificationError.new("expected a history array", check: :history, offset: root_offset)
        end

        count, pointer = Core::Format.pair(history_record(history.value, Core::ArrayList::HEADER_SIZE), "Q>Q>")
        index = count - 1
        levels = [((index.bit_length - 1) / 4), 0].max
        ancestors = @history_offsets << history.value
        levels.downto(0) do |level|
          if ancestors.include?(pointer)
            raise VerificationError.new("cycle in history", check: :history, offset: pointer)
          end

          ancestors << pointer
          block = history_record(pointer, Core::ArrayList::BLOCK_SIZE)
          return nil if count.zero?

          position = ((index >> (level * 4)) & 15) * Core::Slot::SIZE
          @root_offset = pointer + position
          slot = Core::Slot.parse(Core::Format.slice(block, position, Core::Slot::SIZE))
          return history_entry(slot) if level.zero?
          unless slot.tag == :index && !slot.full?
            raise VerificationError.new("invalid history branch", check: :history, offset: root_offset)
          end

          pointer = slot.value
        end
        nil
      end

      def history_record(offset, length)
        if offset + length > bound - Core::Database::TRAILER_SIZE
          raise VerificationError.new("history extends into root trailer", check: :extent, offset: offset)
        end

        read(offset, length)
      end

      def history_entry(slot)
        raise VerificationError.new("missing stored root map", check: :root, offset: root_offset) if slot.tag == :none

        slot
      end
    end
  end
end
