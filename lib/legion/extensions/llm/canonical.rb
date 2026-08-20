# frozen_string_literal: true

require_relative 'canonical/thinking'
require_relative 'canonical/usage'
require_relative 'canonical/params'
require_relative 'canonical/content_block'
require_relative 'canonical/tool_definition'
require_relative 'canonical/tool_schema'
require_relative 'canonical/tool_call'
require_relative 'canonical/message'
require_relative 'canonical/request'
require_relative 'canonical/response'
require_relative 'canonical/chunk'

module Legion
  module Extensions
    module Llm
      # Canonical types for the N×N client→provider routing architecture.
      #
      # These Data.define structs form the single contract between client translators
      # and provider translators. Per Amendment A: immutable, strict factories,
      # enum validation, unknown keys → metadata.
      #
      # Contract version: incremented on any breaking change to the canonical shape.
      # Provider registration refuses gems built against a mismatched version (G7).
      module Canonical
        CONTRACT_VERSION = '1.0.0'

        # Shared strict-factory guards (04 L1/L3/L5/L6) — one implementation for
        # every type. Nil or wrong-class input raises ArgumentError naming the
        # site, member, and offending class. No factory returns nil; unknown
        # keys fold into the metadata member (no drops, no raises).
        module Strict
          module_function

          def require_hash!(source, site)
            return source if source.is_a?(::Hash)

            raise ArgumentError, "#{site}: expected Hash, got #{source.class}"
          end

          def symbolize_keys(hash)
            hash.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          end

          # 04 L5: unknown keys fold into the metadata member.
          def fold_unknowns!(type_class, site, hash)
            metadata = metadata!(hash.delete(:metadata), site)
            known = type_class.members.map(&:to_sym)
            (hash.keys - known).each { |key| metadata[key] = hash.delete(key) }
            metadata
          end

          def metadata!(value, site, member: :metadata)
            return {} if value.nil?

            raise ArgumentError, "#{site}: #{member} expected Hash, got #{value.class}" unless value.is_a?(::Hash)

            value
          end

          def enum!(value, allowed, site, member)
            return value if value.nil? || allowed.include?(value)

            raise ArgumentError,
                  "#{site}: Invalid #{member}: #{value.inspect}. Must be one of: #{allowed.join(', ')}"
          end

          def expect_type!(value, allowed, site, member)
            return value if value.nil? || allowed.any? { |klass| value.is_a?(klass) }

            raise ArgumentError,
                  "#{site}: #{member} expected #{allowed.map(&:name).join(' | ')}, got #{value.class}"
          end
        end

        # Available canonical types (the frozen 04 §1 inventory).
        TYPES = %i[
          Message ContentBlock ToolCall ToolDefinition ToolSchema
          Params Thinking Thinking::Config
          Request Response Chunk Usage
        ].freeze

        class << self
          # List all canonical type classes.
          def types
            TYPES.map { |name| name.to_s.split('::').reduce(self) { |mod, part| mod.const_get(part) } }
          end

          # Check if a given constant name is a registered canonical type.
          def type?(name)
            TYPES.include?(name.to_sym)
          end
        end
      end
    end
  end
end
