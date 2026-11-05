# frozen_string_literal: true

module XitDB
  # A captured root map with an optional committed revision.
  #
  # Reading later commits leaves this map unchanged. It remains tied to its
  # database handle; use {#to_ruby} before closing when you need independent data.
  class Snapshot < Views::Map
    # @return [Revision, nil] saved identity, or nil for the initial empty root
    attr_reader :revision

    # Create a root map bound to a committed read boundary.
    # @api private
    # @param context [Context] read-only owner
    # @param revision [Revision, nil] nil for the initial empty state
    def initialize(context:, revision:)
      @revision = revision
      super(context: context, path: [], kind: :map)
    end
  end
end
