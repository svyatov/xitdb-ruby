# frozen_string_literal: true

require_relative "errors"

module XitDB
  module InputGuard
    def self.check!(value, path: [])
      unless Object === value
        raise UnsupportedValueError.new("unsupported Ruby object", path: path)
      end

      unless Object.instance_method(:singleton_methods).bind_call(value).empty?
        raise UnsupportedValueError.new("singleton behavior is unsupported", path: path)
      end

      klass = Object.instance_method(:class).bind_call(value)
      %i[public protected private].each do |visibility|
        expected = Module.instance_method("#{visibility}_instance_methods").bind_call(klass)
        actual = Object.instance_method("#{visibility}_methods").bind_call(value)
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
