# frozen_string_literal: true

require_relative "../input_guard"

module XitDB
  # Defines how Ruby objects map to stored scalar values, keys, and collection layouts.
  # The portable profile follows native xitdb layouts; the Ruby profile also preserves Ruby types and insertion order.
  module Profiles
    # Stores a shared subset of Ruby values in native xitdb layouts.
    # Scalars include nil, signed and unsigned 64-bit integers, Float values, and byte strings.
    # Map keys and set members must be Strings and use raw byte identity.
    # Untagged strings decode as UTF-8 when valid and as binary otherwise.
    # Native maps use the configured hasher; sorted collections compare raw key bytes.
    class Portable
      # Maps native storage tags to the logical kinds used by public collection views.
      KINDS = {
        hash_map: :map, counted_hash_map: :map, sorted_map: :sorted_map,
        hash_set: :set, counted_hash_set: :set, sorted_set: :sorted_set,
        array_list: :array, linked_array_list: :linked_array
      }.freeze

      # Hash algorithm for portable maps and sets.
      #
      # @return [Core::Hasher] hash algorithm for portable maps and sets
      attr_reader :hasher

      # Selects the hash algorithm used for portable hash maps and sets.
      #
      # @param hasher [Core::Hasher] algorithm matching the database header, SHA-1 by default
      # @raise [TypeError] if the hasher is not a Core::Hasher
      def initialize(hasher: Core::Hasher.sha1)
        raise TypeError, "hasher must be a Core::Hasher" unless hasher.is_a?(Core::Hasher)

        @hasher = hasher
        freeze
      end

      # Stores one portable scalar using native slots or bytes.
      # Use Core::ByteValue to preserve an explicit byte format tag.
      #
      # @param value [nil, Integer, UInt, Float, String, Core::ByteValue] portable scalar
      # @param core [Core::Database] destination storage
      # @return [Core::Slot] stored scalar descriptor
      # @raise [UnsupportedValueError] if the scalar class or singleton behavior is unsupported
      # @raise [RangeError] if an integer exceeds the native 64-bit range
      def encode_scalar(value, core:)
        InputGuard.check!(value)
        case value
        when nil then Core::Slot.null
        when UInt then Core::Slot.uint(value.value)
        when Integer
          value > (1 << 63) - 1 ? Core::Slot.uint(value) : Core::Slot.int(value)
        when Float then Core::Slot.float(value)
        when String then core.bytes(value)
        when Core::ByteValue then core.bytes(value.bytes, format_tag: value.format_tag)
        else
          raise UnsupportedValueError, "unsupported portable scalar: #{Object.instance_method(:class).bind_call(value)}"
        end
      end

      # Reads a native scalar and restores signed integers and Float bit patterns.
      # Tagged bytes remain Core::ByteValue objects; untagged bytes become UTF-8 or binary Strings.
      #
      # @param slot [Core::Slot] scalar descriptor
      # @param core [Core::Database] source storage
      # @param bound [Integer, nil] exclusive read limit, or the core default
      # @param immutable [Boolean] whether to freeze returned untagged Strings
      # @return [nil, Integer, Float, String, Core::ByteValue] decoded portable value
      # @raise [UnsupportedValueError] if the slot tag is not a portable scalar tag
      def decode_scalar(slot, core:, bound: nil, immutable: true)
        case slot.tag
        when :none then nil
        when :uint then slot.value
        when :int then slot.value >= (1 << 63) ? slot.value - (1 << 64) : slot.value
        when :float then [slot.value].pack("Q>").unpack1("G")
        when :bytes, :short_bytes
          value = core.read_bytes(slot, bound: bound)
          return value if value.format_tag

          bytes = value.bytes.dup.force_encoding(Encoding::UTF_8)
          bytes.force_encoding(Encoding::BINARY) unless bytes.valid_encoding?
          immutable ? bytes.freeze : bytes
        else
          raise UnsupportedValueError, "unsupported portable scalar tag: #{slot.tag}"
        end
      end

      # Copies a String key as binary bytes and freezes the identity.
      # String encoding labels do not affect portable key identity.
      #
      # @param value [String] portable map key or set member
      # @return [String] frozen binary key bytes
      # @raise [UnsupportedValueError] if the key is not a supported String
      def key_bytes(value)
        InputGuard.check!(value)
        case value
        when String then value.b.freeze
        else raise UnsupportedValueError, "portable keys must be strings"
        end
      end

      # Walks a Ruby value tree and stores each scalar and collection through this profile.
      #
      # @param value [Object] source value or nested collection
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] logical location used in errors
      # @return [Core::Slot] stored root of the encoded value
      # @raise [ValueError] if an input value, key, or collection cannot be represented
      def encode(value, context:, path:)
        ValueWalker.encode(value, context: context, path: path)
      end

      # Returns a lazy view for collections and a decoded Ruby object for scalars.
      #
      # @param slot [Core::Slot] stored value descriptor
      # @param context [Context] source snapshot or transaction context
      # @param path [Array<Object>] logical location of the value
      # @param immutable [Boolean] whether decoded scalar objects are frozen
      # @return [Object] collection view or scalar
      # @raise [ValueError] if stored data cannot be decoded by this profile
      def decode(slot, context:, path:, immutable: true)
        if (kind = KINDS[slot.tag])
          context.view(slot, path: path, kind: kind)
        else
          decode_scalar(slot, core: context.database.core, bound: context.read_bound, immutable: immutable)
        end
      end

      # Recognizes this profile's collection layout and binds it to the context.
      # An empty root is treated as an empty map.
      #
      # @param slot [Core::Slot] candidate collection descriptor
      # @param context [Context] owner of the read or write
      # @param path [Array<Object>] logical collection location
      # @return [Adapter, nil] bound adapter, or nil for a scalar
      def container(slot, context:, path:)
        return nil unless KINDS.key?(slot.tag) || (slot.empty? && path.empty?)

        Adapter.new(self, context.cursor(slot), context: context, path: path)
      end

      # Creates an adapter for a new empty collection at a logical location.
      #
      # @param kind [Symbol, Array(Symbol, Symbol)] collection kind, optionally paired with a sorted key kind
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] logical collection location
      # @return [Adapter] new empty collection adapter
      def empty_container(kind, context:, path:)
        kind = kind.first if kind.is_a?(Array)
        Adapter.new(self, context.cursor(Core::Slot.new), context: context, path: path, tag: kind)
      end

      # Reports the logical kind to preserve during cross-profile copying.
      #
      # @param adapter [Object] source adapter implementing kind
      # @return [Symbol] logical collection kind
      def conversion_kind(adapter)
        adapter.kind
      end

      # Creates a destination collection while copying between profiles.
      #
      # @param kind [Symbol, Array(Symbol, Symbol)] logical collection kind and optional sorted key kind
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] destination collection location
      # @return [Adapter] destination adapter
      def conversion_container(kind, context:, path:)
        kind = kind.first if kind.is_a?(Array)
        tag = { map: :hash_map, set: :hash_set, array: :array_list, linked_array: :linked_array_list }.fetch(kind, kind)
        empty_container(tag, context: context, path: path)
      end

      # Exposes byte-backed scalars for conversion without materializing the entire value.
      #
      # @param slot [Core::Slot] candidate scalar descriptor
      # @param context [Context] source snapshot or transaction context
      # @return [Array, nil] pair of byte source and encoding hint, or nil when inapplicable
      def conversion_bytes(slot, context:)
        return unless %i[bytes short_bytes].include?(slot.tag)

        source = Conversion::ByteSource.new(context, slot)
        [source, source.format_tag ? nil : :portable]
      end

      # Copies a streamed scalar into this profile using its encoding hint.
      #
      # @param source [Conversion::ByteSource] bounded source bytes
      # @param encoding [Symbol, Encoding, nil] conversion hint identifying portable, binary, encoded, or tagged bytes
      # @param context [Context] destination transaction context
      # @param path [Array<Object>] destination location used in errors
      # @return [Core::Slot] descriptor for the copied bytes
      # @raise [ValueError] if the source cannot be represented by this profile
      def copy_conversion_bytes(source, encoding, context:, path:)
        source.write_to(context, format_tag: encoding ? nil : source.format_tag)
      rescue ValueError => e
        raise e.class.new(e.message, path: path), cause: e
      end

      # Validates a candidate collection and identifies its storage kind.
      # Scalar values return nil and are handled by the scalar encoder.
      #
      # @param value [Object] candidate input
      # @param path [Array<Object>] logical input location used in errors
      # @return [Symbol, Array(Symbol, Symbol), nil] recognized kind and optional key kind
      # @raise [UnsupportedValueError] if collection behavior cannot be preserved
      def input_kind(value, path:)
        InputGuard.check!(value, path: path)
        klass = Object.instance_method(:class).bind_call(value)
        case value
        when Hash, Array, Set
          validate_container!(value, klass, path)
          { Hash => :hash_map, Array => :array_list, Set => :hash_set }.fetch(klass)
        when CollectionDeclaration
          if value.key_kind
            raise UnsupportedValueError.new("typed sorted declarations require the Ruby profile", path: path)
          end

          value.kind
        end
      end

      # Detects Hash settings that this profile cannot preserve.
      #
      # @param value [Hash] input hash
      # @return [Boolean] whether a default value, default procedure, or identity comparison is configured
      def hash_defaults?(value)
        default = !BasicObject.instance_method(:equal?).bind_call(value.default, nil)
        !value.default_proc.nil? || default || value.compare_by_identity?
      end

      # Rejects collection subclasses and comparison or default behavior that cannot be stored.
      #
      # @param value [Hash, Array, Set] input collection
      # @param klass [Class] exact class obtained without application reflection
      # @param path [Array<Object>] logical input location used in errors
      # @return [void]
      # @raise [UnsupportedValueError] if the collection is a subclass or has unsupported behavior
      def validate_container!(value, klass, path)
        unless [Hash, Array, Set].include?(klass)
          raise UnsupportedValueError.new("container subclasses and singleton behavior are unsupported", path: path)
        end
        if value.is_a?(Hash) && hash_defaults?(value)
          raise UnsupportedValueError.new("Hash defaults and identity comparison are unsupported", path: path)
        end
        return unless value.is_a?(Set) && value.compare_by_identity?

        raise UnsupportedValueError.new("Set identity comparison is unsupported", path: path)
      end

      # Lazily validates keys and produces selectors with their child values.
      # Distinct input keys with the same portable bytes raise KeyCollisionError during enumeration.
      # Arrays use integer positions; sets use their members as selectors.
      #
      # @param value [Hash, Array, Set, CollectionDeclaration] input collection
      # @param path [Array<Object>] logical parent location used in key errors
      # @return [Enumerator<Array(Object, Object)>] selector and child-value pairs
      # @raise [ValueError] during enumeration if a key cannot be represented
      # @raise [KeyCollisionError] during enumeration if distinct input keys have identical portable bytes
      def input_entries(value, path:)
        Enumerator.new do |output|
          # @type var seen: Hash[String, bool]
          seen = {}
          case value
          when Hash, Set
            entries = value.is_a?(Hash) ? value.each_pair : value.each.lazy.map { |member| [member, member] }
            entries.each do |key, child|
              begin
                bytes = key_bytes(key)
              rescue ValueError => e
                raise e.class.new(e.message, path: path + [key]), cause: e
              end
              if seen.key?(bytes)
                raise KeyCollisionError.new("distinct input keys have equal portable bytes", path: path + [key])
              end

              seen[bytes] = true
              output << [key, child]
            end
          when Array
            value.each_with_index { |child, index| output << [index, child] }
          end
        end
      end
    end
  end
end

require_relative "portable/adapter"
