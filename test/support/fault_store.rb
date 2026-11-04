# frozen_string_literal: true

class FaultStore
  attr_accessor :fault, :after_fault, :release_fault
  attr_reader :events

  def initialize(store)
    @store = store
    @events = []
  end

  def method_missing(name, *args, **kwargs, &block)
    @events << [name, args]
    @fault&.call(name, args)
    result = @store.public_send(name, *args, **kwargs, &block)
    @after_fault&.call(name, args)
    result
  ensure
    @release_fault&.call if name == :with_exclusive_lock
  end

  def respond_to_missing?(name, include_private = false)
    @store.respond_to?(name, include_private) || super
  end
end
