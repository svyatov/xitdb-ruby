# frozen_string_literal: true

module XitDB
  # Base class for database errors.
  class Error < StandardError; end
  # An unsupported on-disk format version.
  class FormatVersionError < Error; end
  # Invalid structural data in the database file.
  class CorruptionError < Error; end
  # A database opened with an incompatible value profile.
  class ProfileMismatchError < Error; end
  # An operation outside the allowed transaction state.
  class TransactionStateError < Error; end
  # An operation on a closed database.
  class ClosedError < Error; end
  # A view whose transaction or location has expired.
  class ExpiredViewError < Error; end
  # A revision from another database.
  class ForeignRevisionError < Error; end
  # A mutation through a read-only handle.
  class ReadOnlyError < Error; end
  # A mutation that conflicts with an active iterator or stream.
  class ConcurrentModificationError < Error; end
  # A database lock that could not be acquired.
  class BusyError < Error; end
  # A custom value codec failed.
  class CodecError < Error; end
  # Invalid or conflicting codec registrations.
  class CodecConfigurationError < CodecError; end

  # An invalid value with an owned, immutable diagnostic path.
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
      when Hash then Hash.instance_method(:to_h).bind_call(value) do |key, part|
        [copy_path(key), copy_path(part)]
      end.freeze
      when String then String.new(value).freeze
      when NilClass, TrueClass, FalseClass, Integer, Float, Symbol then value
      else
        klass = Object.instance_method(:class).bind_call(value)
        name = Module.instance_method(:name).bind_call(klass) || "anonymous class"
        "#<unsupported #{name}>".freeze
      end
    end
  end

  # A malformed encoded value.
  class InvalidValueError < ValueError; end
  # A value that the selected profile cannot store.
  class UnsupportedValueError < ValueError; end
  # An unsupported scalar encoding or version.
  class UnsupportedEncodingError < ValueError; end
  # A recursive input that cannot be stored as a value.
  class CyclicValueError < ValueError; end
  # A view or value owned by another database.
  class ForeignValueError < ValueError; end
  # Distinct keys with identical encoded representations.
  class KeyCollisionError < ValueError; end

  # A failed commit with its observed durability outcome.
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
