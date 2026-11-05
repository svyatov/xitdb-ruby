# frozen_string_literal: true

require_relative "errors"

module XitDB
  # Rejects objects with altered method behavior before encoding them.
  # @api private
  module InputGuard
    # Reject objects whose per-object methods can change native encoding behavior.
    #
    # Bound native methods inspect the object without trusting its own overrides.
    # @param value [Object]
    # @param path [Array<Object>] logical location for a value error
    # @return [void]
    # @raise [UnsupportedValueError] if singleton behavior or removed methods are detected
    def self.check!(value, path: [])
      unless Object.instance_method(:is_a?).bind_call(value, Object)
        raise UnsupportedValueError.new("unsupported Ruby object", path: path)
      end

      unless Object.instance_method(:singleton_methods).bind_call(value).empty?
        raise UnsupportedValueError.new("singleton behavior is unsupported", path: path)
      end

      klass = Object.instance_method(:class).bind_call(value)
      # @type var methods: ::Array[native_visibility_pair]
      methods = [%i[public_instance_methods public_methods], %i[protected_instance_methods protected_methods],
                 %i[private_instance_methods private_methods]]
      methods.each do |instance_methods, object_methods|
        expected = Module.instance_method(instance_methods).bind_call(klass)
        actual = Object.instance_method(object_methods).bind_call(value)
        unless (expected - actual).empty? && (actual - expected).empty?
          raise UnsupportedValueError.new("singleton behavior or method removal is unsupported", path: path)
        end
      end
      # Private singleton overrides are absent from #singleton_methods. Inspect
      # their owners without creating a singleton class on chilled Strings.
      Object.instance_method(:private_methods).bind_call(value, false).each do |name|
        owner = Object.instance_method(:method).bind_call(value, name).owner
        expected = Module.instance_method(:instance_method).bind_call(klass, name).owner
        unless BasicObject.instance_method(:equal?).bind_call(owner, expected)
          raise UnsupportedValueError.new("singleton behavior is unsupported", path: path)
        end
      end
    end
  end
end
