# frozen_string_literal: true

require_relative "errors"

module XitDB
  module InputGuard
    def self.check!(value, path: [])
      unless Object === value
        raise UnsupportedValueError.new("unsupported Ruby object", path: path)
      end

      begin
        singleton = Object.instance_method(:singleton_class).bind_call(value)
      rescue TypeError
        # Immediate values and frozen Strings without a singleton class cannot add one.
        return
      end
      klass = Object.instance_method(:class).bind_call(value)
      Module.instance_method(:ancestors).bind_call(singleton).each do |ancestor|
        break if ancestor.equal?(klass)

        %i[public_instance_methods protected_instance_methods private_instance_methods].each do |visibility|
          unless Module.instance_method(visibility).bind_call(ancestor, false).empty?
            raise UnsupportedValueError.new("singleton behavior is unsupported", path: path)
          end
        end
      end
    end
  end
end
