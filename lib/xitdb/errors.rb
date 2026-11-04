# frozen_string_literal: true

module XitDB
  class Error < StandardError; end
  class FormatVersionError < Error; end
  class CorruptionError < Error; end
  class ProfileMismatchError < Error; end
  class TransactionStateError < Error; end
  class ClosedError < Error; end
  class ExpiredViewError < Error; end
  class ForeignRevisionError < Error; end
  class ReadOnlyError < Error; end
  class ConcurrentModificationError < Error; end
  class BusyError < Error; end
  class CodecError < Error; end
  class CodecConfigurationError < CodecError; end

  class ValueError < Error
    attr_reader :path

    def initialize(message = nil, path: [])
      @path = copy_path(path)
      super(message)
    end

    private

    def copy_path(value)
      case value
      when Array then Array.instance_method(:map).bind_call(value) { |part| copy_path(part) }.freeze
      when Hash then Hash.instance_method(:to_h).bind_call(value) { |key, part| [copy_path(key), copy_path(part)] }.freeze
      when String then String.new(value).freeze
      when nil, true, false, Integer, Float, Symbol then value
      else
        klass = Object.instance_method(:class).bind_call(value)
        name = Module.instance_method(:name).bind_call(klass) || "anonymous class"
        "#<unsupported #{name}>".freeze
      end
    end
  end

  class InvalidValueError < ValueError; end
  class UnsupportedValueError < ValueError; end
  class UnsupportedEncodingError < ValueError; end
  class CyclicValueError < ValueError; end
  class ForeignValueError < ValueError; end
  class KeyCollisionError < ValueError; end

  class CommitError < Error
    attr_reader :outcome

    def initialize(message = nil, outcome:)
      unless %i[not_committed committed unknown].include?(outcome)
        raise ArgumentError, "invalid commit outcome: #{outcome.inspect}"
      end

      @outcome = outcome
      super(message)
    end
  end
end
