# frozen_string_literal: true

module XitDB
  module Ruby
    # Keeps fixed-size groups of flat rows in independently replaceable pages.
    # @api private
    class PageArray < Containers
      # rubocop:disable-next Lint/MissingSuper
      def initialize(profile, cursor, context:, path:, record:)
        @profile = profile
        @cursor = cursor
        @context = context
        @path = path
        @kind = :array
        @fallback = nil
        fields = record.fields
        invalid! unless !cursor.slot.full? && fields.size == 2 && fields.none?(&:full?) &&
                        fields.fetch(0).tag == :uint && fields.fetch(1).tag == :array_list

        @count = fields.fetch(0).value
        @pages = Core::ArrayList.new(context.cursor(fields.fetch(1)))
        invalid! unless @count.positive? && @pages.size == (@count + Pages::ROW_LIMIT - 1) / Pages::ROW_LIMIT
      end

      def size
        fallback = @fallback
        fallback ? fallback.size : @count
      end

      def lookup(selector)
        fallback = @fallback
        return fallback.lookup(selector) if fallback

        index = index_selector!(selector)
        index += size if index.negative?
        return unless index >= 0 && index < size

        page_index, row_index = index.divmod(Pages::ROW_LIMIT)
        page = page_slot!(page_index)
        if page.tag == :record
          generic_page(page, page_index).lookup(row_index)
        else
          PageReference.new(page, row_index, page_size(page_index))
        end
      end

      def each_entry
        return enum_for(:each_entry) unless block_given?

        size.times { |index| yield index, required_slot!(lookup(index)) }
        self
      end

      def materialize_flat
        return if @fallback

        # @type var output: Array[PageCodec::row]
        output = []
        @pages.each.with_index do |page, index|
          return nil if page.tag == :record

          output.concat(PageCodec.decode_page(Pages.bytes(page, @context), page_size(index)))
        end
        output
      end

      def assign(selector, stored)
        index = index_selector!(selector)
        if @fallback || index == size
          promote.assign(index, stored)
        else
          index += size if index.negative?
          raise IndexError, "array index outside list" unless index >= 0 && index < size

          replace_row(index, stored)
        end
        publish
      end

      def insert(index, stored)
        promote.insert(index, stored)
        publish
      end

      def delete(selector)
        promote.delete(selector)
        publish
      end

      def truncate(count)
        promote.truncate(count)
        publish
      end

      def clear
        promote.clear
        publish
      end

      private

      def page_size(index)
        [Pages::ROW_LIMIT, @count - (index * Pages::ROW_LIMIT)].min
      end

      def page_slot!(index)
        page = required_slot!(@pages.get(index))
        invalid! if page.full? || !%i[bytes short_bytes record].include?(page.tag)
        page
      end

      def generic_page(page, index)
        record = Core::Record.read(@context.database.core, page, bound: @context.read_bound)
        invalid! unless [PackedArray::INLINE, PackedArray::TREE].include?(record.metadata)

        adapter = PackedArray.new(@profile, @context.cursor(page), context: @context, path: @path, record: record)
        invalid! unless adapter.size == page_size(index)

        adapter
      end

      def replace_row(index, stored)
        page_index, row_index = index.divmod(Pages::ROW_LIMIT)
        page = page_slot!(page_index)
        if page.tag == :record
          adapter = generic_page(page, page_index)
          adapter.assign(row_index, stored)
          @pages.put(page_index, adapter.slot)
          return
        end

        rows = PageCodec.decode_page(Pages.bytes(page, @context), page_size(page_index))
        replacement = flat_row(stored)
        if replacement
          rows[row_index] = replacement
          bytes = PageCodec.encode_stored_page(rows)
          if bytes
            @pages.put(page_index, @context.database.core.bytes(bytes))
            return
          end
        end
        adapter = promote_page(page, page_index)
        adapter.assign(row_index, stored)
        @pages.put(page_index, adapter.slot)
      end

      def flat_row(stored)
        return stored.decoded if stored.is_a?(PageDraft)

        adapter = @profile.container(stored, context: @context, path: @path)
        return unless adapter && adapter.kind == :map && adapter.size <= 16

        # @type var output: PageCodec::row
        output = {}
        adapter.each_entry do |key, cell|
          return nil unless key.is_a?(String)
          return nil unless page_cell?(cell)

          value = @profile.decode(cell, context: @context, path: @path, immutable: false)
          case value
          when NilClass, TrueClass, FalseClass, Integer, Float, String then output[key] = value
          else return nil
          end
        end
        output
      end

      # Recognizes built-in cells without invoking application decoders.
      def page_cell?(slot)
        return true if slot.is_a?(PageCell) || %i[none int uint float].include?(slot.tag)
        return false unless slot.full? && %i[bytes short_bytes].include?(slot.tag)

        source = Core::Bytes.open(@context.database.core, slot, bound: @context.read_bound)
        return false unless source.format_tag == "rb" && source.size.between?(2, Pages::BYTE_LIMIT)

        prefix = source.read(0, 2)
        prefix == "\x01\x01".b || prefix == "\x01\x03".b
      end

      def promote_page(page, index)
        output = PackedArray.new(@profile, @context.cursor(Core::Slot.new), context: @context, path: @path,
                                                                            kind: :array, defer: true)
        count = page_size(index)
        count.times { |row_index| output.assign(row_index, PageReference.new(page, row_index, count)) }
        output.slot
        output
      end

      def promote
        fallback = @fallback
        return fallback if fallback

        output = PackedArray.new(@profile, @context.cursor(Core::Slot.new), context: @context, path: @path,
                                                                            kind: :array, defer: true)
        each_entry { |index, stored| output.assign(index, stored) }
        output.slot
        @fallback = output
      end

      def publish
        fallback = @fallback
        stored = if fallback
                   fallback.slot
                 else
                   Core::Record.append(@context.writable_transaction!, metadata: Pages::ARRAY,
                                                                       fields: [Core::Slot.uint(@count),
                                                                                @pages.cursor.slot])
                 end
        cursor.replace(stored)
        self
      end

      def invalid!
        raise InvalidValueError, "invalid Ruby page array"
      end
    end
  end
end
