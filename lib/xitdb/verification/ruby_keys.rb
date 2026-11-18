# frozen_string_literal: true

module XitDB
  module Verification
    # Bounds the original scalar, decoded key and its canonical representation.
    module RubyKeys
      private

      def with_key(slot, offset, kind: :ordinary, packed: false)
        bytes = Graph::BYTE_TAGS.include?(slot.tag)
        size = bytes ? byte_size(slot) : 8
        invalid!(:key_identity, offset) if packed && size > Ruby::PackedMap::MAX_KEY_PAYLOAD
        # Continued-fraction Time ordering emits at most one quotient per input
        # bit plus its length and terminator. Other keys need at most one
        # transcoded string, integer magnitude or complemented sort key.
        factor = kind == :time ? 512 : 48
        @scan.budget.with(:scalar_bytes, (size + 16) * factor) do
          key = decode_key(slot, offset, size, kind)
          identity = if kind == :ordinary
                       Ruby::KeyEncoding.dump_stored(key)
                     else
                       Ruby::OrderedKeys.dump(key, kind: kind)
                     end
          invalid!(:key_identity, offset) if packed && identity.bytesize > Ruby::PackedMap::MAX_KEY_BYTES
          yield identity, key_selector(key)
        end
      rescue ValueError, EncodingError, RangeError, ArgumentError
        invalid!(:key_identity, offset)
      end

      def key_selector(key)
        case key
        when String, Symbol
          bytes = key.to_s.b
          sample = Core::Format.slice(bytes, 0, 32).dump
          bytes.bytesize > 32 ? "#{sample}[...key]" : sample
        when Integer then key.bit_length <= 64 ? key.to_s : "integer key"
        when Time then "time key"
        else key.inspect
        end
      end

      def decode_key(slot, offset, size, kind)
        case slot.tag
        when :none then nil
        when :int then slot.value[63].zero? ? slot.value : slot.value - (1 << 64)
        when :uint then slot.value
        when :float then [slot.value].pack("Q>").unpack1("G")
        when :bytes, :short_bytes then decode_key_bytes(slot, offset, size, kind)
        else invalid!(:key_identity, offset)
        end
      end

      def decode_key_bytes(slot, offset, size, kind)
        return byte_data(slot, size) unless slot.full?

        tag = if slot.tag == :bytes
                @scan.read(slot.value + 8 + size, 2)
              else
                Core::Format.slice([slot.value].pack("Q>"), 6, 2)
              end
        invalid!(:key_identity, offset) unless tag == "rb"
        Ruby::Scalars.decode_key_payload(byte_data(slot, size), time: kind == :time)
      end
    end
  end
end
