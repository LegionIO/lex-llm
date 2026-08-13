# frozen_string_literal: true

require 'legion/extensions/llm/inventory/errors'

module Legion
  module Extensions
    module Llm
      module Inventory
        # The single strict recursive copier/freezer for JSON-like metadata and
        # collection fields. See phase-1-lex-llm-additive.md section 7.1.
        #
        # Records call this helper before `super`; they never implement a
        # competing recursive-freeze helper. It recursively copies and freezes
        # only nil, true/false, Symbol, Integer, finite Float, String, Time,
        # Array, and Hash. Hash keys must be String or Symbol. Strings must be
        # valid UTF-8. Time values are duplicated and frozen. Arrays and Hashes
        # preserve order but never preserve a mutable nested reference. NaN,
        # infinity, an unsupported object, a callable, or a cyclic Array/Hash
        # raises ValidationError naming the field path.
        module ImmutableValue
          module_function

          def copy_and_freeze(value:, field:)
            deep_copy(value, field.to_s, [])
          end

          def deep_copy(value, path, ancestors)
            case value
            when nil, true, false, ::Symbol, ::Integer
              value
            when ::Float
              raise Errors::ValidationError, "#{path} is not a finite Float" unless value.finite?

              value
            when ::String
              raise Errors::ValidationError, "#{path} is not valid UTF-8" unless valid_utf8?(value)

              value.dup.freeze
            when ::Time
              value.dup.freeze
            when ::Array
              copy_array(value, path, ancestors)
            when ::Hash
              copy_hash(value, path, ancestors)
            else
              raise Errors::ValidationError, "#{path} is an unsupported value type (#{value.class})"
            end
          end
          # rubocop:enable Metrics/MethodLength

          def copy_array(value, path, ancestors)
            raise Errors::ValidationError, "#{path} contains a cyclic Array reference" if cyclic?(value, ancestors)

            next_ancestors = ancestors + [value]
            value.each_with_index.map do |element, index|
              deep_copy(element, "#{path}[#{index}]", next_ancestors)
            end.freeze
          end

          def copy_hash(value, path, ancestors)
            raise Errors::ValidationError, "#{path} contains a cyclic Hash reference" if cyclic?(value, ancestors)

            next_ancestors = ancestors + [value]
            copied = {}
            value.each do |key, element|
              frozen_key = copy_key(key, path)
              copied[frozen_key] = deep_copy(element, "#{path}.#{key}", next_ancestors)
            end
            copied.freeze
          end

          def copy_key(key, path)
            case key
            when ::Symbol
              key
            when ::String
              raise Errors::ValidationError, "#{path} has a key that is not valid UTF-8" unless valid_utf8?(key)

              key.dup.freeze
            else
              raise Errors::ValidationError, "#{path} has a non-String/Symbol key (#{key.class})"
            end
          end

          def cyclic?(value, ancestors)
            ancestors.any? { |ancestor| ancestor.equal?(value) }
          end

          def valid_utf8?(string)
            [::Encoding::UTF_8, ::Encoding::US_ASCII].include?(string.encoding) && string.valid_encoding?
          end
        end
      end
    end
  end
end
