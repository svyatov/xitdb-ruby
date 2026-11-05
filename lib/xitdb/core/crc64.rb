# frozen_string_literal: true

module XitDB
  module Core
    # The checksum calculation used to detect invalid committed root trailers.
    # @api private
    module CRC64
      # Unsigned 64-bit mask used to initialize and finish the checksum.
      MASK = 0xffffffffffffffff
      # Reflected polynomial used by the checksum bit updates.
      POLYNOMIAL = 0xc96c5795d7870f42

      # Calculates the 64-bit checksum used to validate a committed root trailer.
      # @param bytes [String] binary input bytes
      # @return [Integer]
      # @raise [TypeError] if bytes is not a String
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
