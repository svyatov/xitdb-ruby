# frozen_string_literal: true

module XitDB
  module Ruby
    # Keeps short arrays in one record and larger arrays in a bounded slot tree.
    # @api private
    class PackedArray < Containers
      INLINE = 2
      TREE = 3
      MAX_FIELDS = 16

      # Packed arrays initialize their fields without an indexed envelope.
      # rubocop:disable-next Lint/MissingSuper
      def initialize(profile, cursor, context:, path:, kind: nil, defer: false, record: nil)
        @profile = profile
        @cursor = cursor
        @context = context
        @path = path
        @kind = :array
        @deferred = defer
        @fields = []
        @builder = nil
        @count = 0
        return if kind

        invalid! if cursor.slot.full?
        read_record(record || Core::Record.read(context.database.core, cursor.slot, bound: context.read_bound))
      end

      def slot
        publish if @deferred
        cursor.slot
      end

      def size
        return @count if @builder

        collection = @collection
        collection ? collection.size : @fields.size
      end

      def lookup(selector)
        index = index_selector!(selector)
        finish_builder
        collection = @collection
        collection ? array_collection!.get(index) : @fields[index]
      end

      def assign(selector, stored)
        index = index_selector!(selector)
        if (builder = @builder)
          raise IndexError, "unpublished array construction must append" unless index == size

          builder.append(stored)
          @count += 1
        elsif @collection
          return super
        else
          assign_inline(index, stored)
        end
        publish unless @deferred
        self
      end

      def insert(index, stored)
        finish_builder
        return super if @collection

        raise IndexError, "array index outside list" unless index.between?(0, size)

        @fields.insert(index, stored)
        start_builder if @fields.size > MAX_FIELDS
        publish
      end

      def delete(selector)
        finish_builder
        return super if @collection

        index = index_selector!(selector)
        raise IndexError, "array index outside list" unless index >= 0 && index < size

        @fields.delete_at(index)
        publish
      end

      def truncate(count)
        finish_builder
        Core::Format.integer!(count, 0..size)
        return super if @collection && count > MAX_FIELDS

        @fields = Array.new(count) { |index| required_slot!(lookup(index)) }
        @collection = nil
        publish
      end

      def clear
        @fields.clear
        @collection = nil
        @builder = nil
        @count = 0
        publish
      end

      def each_entry
        return enum_for(:each_entry) unless block_given?

        finish_builder
        collection = @collection
        if collection
          array_collection!.each.with_index { |stored, index| yield index, stored }
        else
          @fields.each_with_index { |stored, index| yield index, stored }
        end
        self
      end

      private

      def assign_inline(index, stored)
        if index == size
          @fields << stored
          start_builder if @fields.size > MAX_FIELDS
        else
          index += size if index.negative?
          raise IndexError, "array index outside list" unless index >= 0 && index < size

          @fields[index] = stored
        end
      end

      def read_record(record)
        fields = record.fields
        case record.metadata
        when INLINE
          invalid! if fields.size > MAX_FIELDS
          @fields = fields.dup
        when TREE
          invalid! unless fields.size == 1 && fields.fetch(0).tag == :array_list
          @collection = Core::ArrayList.new(@context.cursor(fields.fetch(0)))
        else invalid!
        end
      end

      def start_builder
        builder = Core::ArrayBuilder.new(@context.writable_transaction!)
        @fields.each { |stored| builder.append(stored) }
        @builder = builder
        @count = @fields.size
        @fields.clear
      end

      def finish_builder
        builder = @builder
        return unless builder

        @collection = Core::ArrayList.new(@context.cursor(builder.slot))
        @builder = nil
      end

      def publish
        finish_builder
        collection = @collection
        fields = collection ? [collection.cursor.slot] : @fields
        stored = Core::Record.append(@context.writable_transaction!, metadata: collection ? TREE : INLINE,
                                                                     fields: fields)
        cursor.replace(stored)
        @deferred = false
        self
      end

      def invalid!
        raise InvalidValueError, "invalid packed Ruby array"
      end
    end
  end
end
