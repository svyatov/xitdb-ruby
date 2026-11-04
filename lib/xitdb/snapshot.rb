# frozen_string_literal: true

module XitDB
  class Snapshot < Views::Map
    attr_reader :revision

    def initialize(context:, revision:)
      @revision = revision
      super(context: context, path: [], kind: :map)
    end
  end
end
