# frozen_string_literal: true

module XitDB
  module Core
    # Calculates the checksum used by root trailers.
    module CRC64
      MASK = 0xffffffffffffffff
      POLYNOMIAL = 0xc96c5795d7870f42

      def self.call(bytes)
        raise TypeError, "expected String, got #{bytes.class}" unless bytes.is_a?(String)

        crc = MASK
        bytes.each_byte do |byte|
          crc ^= byte
          8.times { crc = (crc >> 1) ^ (crc.odd? ? POLYNOMIAL : 0) }
        end
        crc ^ MASK
      end
    end
  end
end
