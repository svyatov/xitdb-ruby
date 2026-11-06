# frozen_string_literal: true

require "tempfile"

module XitDB
  # Block-scoped access to untagged byte values without full-value reads.
  #
  # Open streams through {Views::Base#open_bytes} or {Views::Base#write_bytes}.
  # Stream methods reject access after the owning block ends.
  module Streams
  end
end

require_relative "streams/handle"
require_relative "streams/reader"
require_relative "streams/writer"
