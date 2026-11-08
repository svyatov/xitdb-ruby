# frozen_string_literal: true

module XitDB
  module Ruby
    # Decodes a selected row lazily within one adapter operation.
    # @api private
    class PageRow < Containers
      # rubocop:disable-next Lint/MissingSuper
      def initialize(profile, cursor, context:, path:, reference:)
        @profile = profile
        @cursor = cursor
        @context = context
        @path = path
        @kind = :map
        @reference = reference
        @row = nil
        @fallback = nil
      end

      def size
        fallback = @fallback
        fallback ? fallback.size : row.size
      end

      def lookup(selector)
        fallback = @fallback
        return fallback.lookup(selector) if fallback

        identity = key_bytes(selector)
        key = row.each_key.find { |candidate| @profile.stored_key_bytes(candidate) == identity }
        key ? PageCell.new(row.fetch(key)) : nil
      end

      def each_entry(&)
        return enum_for(:each_entry) unless block_given?

        fallback = @fallback
        if fallback
          fallback.each_entry(&)
        else
          row.each_pair { |key, value| yield key, PageCell.new(value) }
        end
        self
      end

      def materialize_flat
        return if @fallback

        row.transform_values { |value| value.is_a?(String) ? value.dup : value }
      end

      def assign(selector, stored)
        promote.assign(selector, stored)
        publish
      end

      def delete(selector)
        promote.delete(selector)
        publish
      end

      def clear
        promote.clear
        publish
      end

      private

      def row
        @row ||= PageCodec.decode_row(Pages.bytes(@reference.page, @context), @reference.index, @reference.count)
      end

      def promote
        fallback = @fallback
        return fallback if fallback

        output = PackedMap.new(@profile, @context.cursor(Core::Slot.new), context: @context, path: @path,
                                                                          kind: :map, defer: true)
        row.each_pair { |key, value| output.assign(key, PageCell.new(value)) }
        @fallback = output
      end

      def publish
        cursor.replace(promote.slot)
        self
      end
    end
  end
end
