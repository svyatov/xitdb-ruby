# frozen_string_literal: true

class FaultStore
  attr_accessor :fault
  attr_reader :events, :release_fault

  def initialize(store)
    @store = store
    @events = []
  end

  def method_missing(name, *args, **kwargs, &block)
    @events << [name, args]
    @fault&.call(name, args)
    @store.public_send(name, *args, **kwargs, &block)
  end

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

  def respond_to_missing?(name, include_private = false)
    @store.respond_to?(name, include_private) || super
  end
end
