# frozen_string_literal: true

require_relative "scan"
require_relative "hash_index"
require_relative "tree"

module XitDB
  module Verification
    # Verifies reachable storage within one captured snapshot. Each frame yields
    # its next child and receives that child's completed summary when resumed.
    class Graph
      include HashIndex
      include Tree

      Frame = Data.define(:pointer, :identity, :path, :reader)
      BYTE_TAGS = %i[bytes short_bytes].freeze
      MAP_TAGS = %i[hash_map counted_hash_map sorted_map].freeze
      # A completed tree summary holds four fields and at most two inline keys.
      SUMMARY_BYTES = 64

      def initialize(scan)
        @scan = scan
        @budget = scan.budget
      end

      def verify!(root, role:)
        return unless root

        @portable = role == :portable_root
        raise ArgumentError, "unknown graph role" unless @portable || role == :physical

        @path = "$"
        invalid!(:root, @scan.root_offset) if @portable && !MAP_TAGS.include?(root.tag)
        @active = @scan.history_offsets.to_h { |offset| [offset, true] }
        @layouts = {}
        @completed = {}
        @stack = []
        @retained = 0
        begin
          @stack << Frame.new(nil, nil, @path, Fiber.new { value(root, @scan.root_offset) })
          traverse
        ensure
          @stack.each { |frame| release_frame(frame) if frame.pointer }
          @budget.release(:references, @retained)
          @budget.release(:summary_bytes, @completed.size * SUMMARY_BYTES)
          @completed.clear
          @layouts.clear
        end
        nil
      end

      private

      def traverse
        # @type var result: graph_summary
        result = nil
        until @stack.empty?
          frame = @stack.fetch(-1)
          @path = frame.path
          output = frame.reader.resume(result)
          if frame.reader.alive?
            pointer, layout, context, offset, reader = output
            result = enter(pointer, layout, context, offset, reader)
          else
            complete(frame, output) if frame.pointer
            @stack.pop
            result = output
          end
        end
      end

      def enter(pointer, layout, context, offset, reader)
        invalid!(:cycle, offset) if @active[pointer]
        invalid!(:layout, offset) if @layouts.key?(pointer) && @layouts[pointer] != layout
        identity = [pointer, layout, context]
        return @completed[identity] if @completed.key?(identity)

        path = @budget.path(@path, offset.to_s)
        @budget.reserve!(:references)
        @retained += 1
        @budget.reserve!(:depth)
        begin
          @budget.reserve!(:path_bytes, path.bytesize)
        rescue VerificationLimitError
          @budget.release(:depth)
          raise
        end
        @layouts[pointer] = layout
        @active[pointer] = true
        @stack << Frame.new(pointer, identity, path, Fiber.new(&reader))
        nil
      end

      def complete(frame, output)
        @budget.reserve!(:summary_bytes, SUMMARY_BYTES)
        @completed[frame.identity] = output
        @active.delete(frame.pointer)
        release_frame(frame)
      end

      def release_frame(frame)
        @budget.release(:depth)
        @budget.release(:path_bytes, frame.path.bytesize)
      end

      def reference(pointer, layout, context, offset, &reader)
        Fiber.yield([pointer, layout, context, offset, reader])
      end

      def invalid!(check, offset)
        raise VerificationError.new("invalid #{check.to_s.tr("_", " ")}", check: check, offset: offset, path: @path)
      end

      def read(offset, length)
        limit = @scan.bound - Core::Database::TRAILER_SIZE
        invalid!(:extent, offset) if offset < @scan.header.data_offset || offset + length > limit
        @scan.read(offset, length)
      end

      def slot_at(offset)
        Core::Slot.parse(read(offset, Core::Slot::SIZE))
      end

      def uint(offset)
        Core::Format.unsigned(read(offset, 8))
      end

      def value(slot, offset)
        invalid!(:slot_flag, offset) if slot.full? && ![:none, *BYTE_TAGS].include?(slot.tag)
        case slot.tag
        when :none then invalid!(:null, offset) unless slot.value.zero?
        when :uint, :int, :float then nil
        when :bytes, :short_bytes then bytes(slot, offset)
        else collection(slot, offset)
        end
      end

      def collection(slot, offset)
        reference(slot.value, slot.tag, nil, offset) do
          case slot.tag
          when :array_list then array(slot.value)
          when :hash_map, :counted_hash_map, :hash_set, :counted_hash_set then hash_root(slot)
          when :linked_array_list, :sorted_map, :sorted_set then tree_root(slot)
          when :record
            invalid!(:slot, offset) if @portable
            record(slot.value)
          else invalid!(:slot, offset)
          end
        end
      end

      def record(pointer)
        _metadata, count = Core::Format.pair(read(pointer, Core::Record::HEADER_SIZE), "NN")
        invalid!(:record_count, pointer + 4) if count > Core::Record::MAX_FIELDS
        count.times do |index|
          position = pointer + Core::Record::HEADER_SIZE + (index * 9)
          value(slot_at(position), position)
        end
        nil
      end

      def array(pointer)
        count, block = Core::Format.pair(read(pointer, 16), "Q>Q>")
        level = [((count - 1).bit_length - 1) / 4, 0].max
        array_block(block, level, count, pointer + 8)
      end

      def array_block(pointer, level, count, offset)
        reference(pointer, :array_block, [level, count], offset) do
          read(pointer, Core::ArrayList::BLOCK_SIZE)
          span = 1 << (4 * level)
          count.ceildiv(span).times do |index|
            position = pointer + (index * 9)
            slot = slot_at(position)
            if level.zero?
              value(slot, position)
            elsif slot != Core::Slot.new
              expect_tag!(slot, :index, position)
              array_block(slot.value, level - 1, [span, count - (span * index)].min, position)
            end
          end
          nil
        end
      end

      def expect_tag!(slot, tag, offset)
        invalid!(:slot, offset) unless slot.tag == tag && !slot.full?
      end

      def bytes(slot, offset)
        return inline_bytes(slot, offset) if slot.tag == :short_bytes

        reference(slot.value, :bytes, slot.full?, offset) do
          size = uint(slot.value)
          start = slot.value + 8
          read(start + size, slot.full? ? 2 : 0)
          # @type var source: byte_source
          source = [start, size]
          each_chunk(source) { |_chunk| nil } # Reading every chunk checks its physical extent.
          source
        end
      end

      def inline_bytes(slot, offset)
        data = Core::Format.slice([slot.value].pack("Q>"), 0, slot.full? ? 6 : 8)
        length = data.index("\0") || data.bytesize
        invalid!(:inline_padding, offset) unless Core::Format.slice(data, length..).each_byte.all?(&:zero?)
        [data, length]
      end

      def key_source(slot, offset)
        invalid!(:key, offset) unless BYTE_TAGS.include?(slot.tag) && !slot.full?
        bytes(slot, offset)
      end

      def each_chunk(source)
        location, size = source
        position = 0
        while position < size
          length = [size - position, Scan::CHUNK_SIZE].min
          yield part(location, position, length)
          position += length
        end
      end

      def part(location, position, length)
        location.is_a?(String) ? Core::Format.slice(location, position, length) : read(location + position, length)
      end
    end
  end
end
