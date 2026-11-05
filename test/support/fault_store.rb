# frozen_string_literal: true

# Provides a store wrapper that records calls and injects storage and writer-release failures.

# Delegates storage operations while exposing deterministic fault hooks.
# @api private
class FaultStore
  # Runs before delegation so a test can fail one selected storage operation.
  # @return [Proc, nil] callback receiving the method name and positional arguments
  attr_accessor :fault

  # @!attribute [r] events
  #   @return [Array<Array>] delegated method names and positional argument lists
  # @!attribute [r] release_fault
  #   @return [Proc, nil] callback invoked when the writer lock is released
  attr_reader :events, :release_fault

  # Wraps a real store and starts an empty event log.
  # @param store [Object] store receiving delegated calls
  def initialize(store)
    @store = store
    @events = []
  end

  # Records a call, runs the fault hook, and delegates the operation.
  # @param name [Symbol] delegated method name
  # @param args [Array] positional arguments recorded in the event log
  # @return [Object] delegated result
  def method_missing(name, *args, **, &)
    @events << [name, args]
    @fault&.call(name, args)
    @store.public_send(name, *args, **, &)
  end

  # Installs a hook at writer release while preserving the normal release operation.
  # @param fault [Proc, nil] callback invoked on writer release
  def release_fault=(fault)
    @release_fault = fault
    return if @release_installed

    @release_installed = true
    wrapper = self
    if @store.is_a?(XitDB::Core::FileStore)
      file = @store.instance_variable_get(:@file)
      original = file.method(:flock)
      file.define_singleton_method(:flock) do |mode|
        wrapper.release_fault&.call if mode == File::LOCK_UN
        original.call(mode)
      end
    else
      original = @store.method(:unlock_writer)
      @store.define_singleton_method(:unlock_writer) do
        original.call
        wrapper.release_fault&.call
      end
    end
  end

  # Reports the wrapped store's supported methods to reflection callers.
  # @param name [Symbol] method name
  # @param include_private [Boolean] whether private methods are included
  # @return [Boolean] whether delegation is available
  def respond_to_missing?(name, include_private = false)
    @store.respond_to?(name, include_private) || super
  end
end
