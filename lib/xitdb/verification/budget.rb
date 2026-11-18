# frozen_string_literal: true

module XitDB
  module Verification
    # Accounts for simultaneously retained scan state.
    class Budget
      DEFAULTS = {
        depth: 256, references: 262_144, path_bytes: 1024 * 1024,
        scalar_bytes: 8 * 1024 * 1024, codec_bytes: 1024 * 1024,
        summary_bytes: 16 * 1024 * 1024, comparison_bytes: 16 * 1024 * 1024
      }.freeze
      PATH_SIZE = 1024
      OMISSION = "[...]"

      def initialize(limits = {})
        @limits = DEFAULTS.merge(limits)
        @usage = Hash.new(0)
      end

      def reserve!(name, amount = 1)
        raise ArgumentError, "negative reservation" if amount.negative?

        total = @usage[name] + amount
        raise VerificationLimitError, name if total > @limits.fetch(name)

        @usage[name] = total
      end

      def release(name, amount = 1)
        raise ArgumentError, "invalid release" unless amount.between?(0, @usage[name])

        @usage[name] -= amount
      end

      def with(name, amount)
        reserve!(name, amount)
        begin
          yield
        ensure
          release(name, amount)
        end
      end

      # Build a bounded diagnostic from a prior path and a string selector.
      def path(parent, component)
        return parent if parent.bytesize == PATH_SIZE && parent.end_with?(OMISSION)

        return "#{parent}/#{component}".freeze if parent.bytesize + component.bytesize + 1 <= PATH_SIZE

        space = PATH_SIZE - OMISSION.bytesize
        prefix = Core::Format.slice(parent, 0, space)
        if prefix.bytesize < space
          prefix << "/" << Core::Format.slice(component, 0, space - prefix.bytesize)
          prefix = Core::Format.slice(prefix, 0, space)
        end
        (prefix << OMISSION).freeze
      end
    end
  end
end
