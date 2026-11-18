# frozen_string_literal: true

module XitDB
  module Ruby
    # Stores bounded flat-row pages and persists transient row descriptors.
    # @api private
    module Pages
      MIN_ROWS = 32
      ROW_LIMIT = 1024
      BYTE_LIMIT = 65_536
      ARRAY = 7
      ROW = 8

      def self.encode(input, context:)
        klass = Object.instance_method(:class).bind_call(input)
        return unless BasicObject.instance_method(:equal?).bind_call(klass, ::Array)

        # @type var input: ::Array[top]
        # @type var count: Integer
        count = ::Array.instance_method(:size).bind_call(input)
        return if count < MIN_ROWS

        transaction = context.writable_transaction!
        checkpoint = transaction.checkpoint
        completed = false
        begin
          builder = Core::ArrayBuilder.new(transaction)
          (0...count).step(ROW_LIMIT) do |index|
            length = [ROW_LIMIT, count - index].min
            # @type var rows: ::Array[top]?
            rows = ::Array.instance_method(:slice).bind_call(input, index, length)
            return nil unless rows && rows.size == length

            bytes = PageCodec.encode_page(rows)
            return nil unless bytes

            builder.append(context.database.core.bytes(bytes))
          end
          return nil unless count == ::Array.instance_method(:size).bind_call(input)

          stored = Core::Record.append(transaction, metadata: ARRAY,
                                                    fields: [Core::Slot.uint(count), builder.slot])
          completed = true
          stored
        ensure
          completed ? transaction.release_checkpoint(checkpoint) : transaction.restore(checkpoint)
        end
      end

      def self.persist(slot, context)
        case slot
        when PageReference
          Core::Record.append(context.writable_transaction!, metadata: ROW,
                                                             fields: [slot.page, Core::Slot.uint(slot.index),
                                                                      Core::Slot.uint(slot.count)])
        when PageCell
          context.profile.encode_scalar(slot.decoded, core: context.database.core)
        when PageDraft
          context.profile.encode(slot.decoded, context: context, path: [])
        else slot
        end
      end

      def self.bytes(slot, context)
        unless %i[bytes short_bytes].include?(slot.tag) && !slot.full?
          raise InvalidValueError, "invalid Ruby page byte descriptor"
        end

        source = Core::Bytes.open(context.database.core, slot, bound: context.read_bound)
        raise InvalidValueError, "Ruby page exceeds byte limit" if source.size > BYTE_LIMIT

        source.read(0, source.size)
      end

      def self.reference(record)
        fields = record.fields
        unless record.metadata == ROW && fields.size == 3 && fields.none?(&:full?) &&
               %i[bytes short_bytes].include?(fields.fetch(0).tag) &&
               fields.fetch(1).tag == :uint && fields.fetch(2).tag == :uint
          raise InvalidValueError, "invalid Ruby page row descriptor"
        end

        page = fields.fetch(0)
        index = fields.fetch(1)
        count = fields.fetch(2)
        unless count.value.between?(1, ROW_LIMIT) && index.value < count.value
          raise InvalidValueError, "invalid Ruby page row bounds"
        end

        PageReference.new(page, index.value, count.value)
      end
    end
  end
end
