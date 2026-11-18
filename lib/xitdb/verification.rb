# frozen_string_literal: true

require_relative "verification/graph"

# Public entry point for read-only snapshot verification.
module XitDB
  # The checked profile, hash configuration, exclusive committed boundary and
  # distinct application codec identifiers reachable from the latest snapshot.
  VerificationResult = Data.define(:profile, :hash_id, :hash_size, :committed_size, :codec_ids)

  # Verify the latest snapshot through one read-only file descriptor.
  # @param path [String] existing database file
  # @return [VerificationResult] immutable description of the checked snapshot
  # @raise [VerificationError] if a reachable structure is invalid
  # @raise [UnsupportedVerificationFormatError] if the file format is unsupported
  # @raise [VerificationLimitError] if the scan exceeds a resource limit
  # @raise [SystemCallError] if a filesystem operation fails
  def self.verify!(path)
    Verification::Scan.open(path) do |scan|
      role = scan.profile == :portable ? :portable_root : :ruby_root
      Verification::Graph.new(scan).verify!(scan.root, role: role)
      VerificationResult.new(profile: scan.profile, hash_id: scan.header.hash_id, hash_size: scan.header.hash_size,
                             committed_size: scan.bound, codec_ids: scan.codec_ids)
    end
  end
end
