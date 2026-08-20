# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Canonical
        TOOL_NAME_MAX_LENGTH = 64
        OBJECT_SCHEMA_KEYWORDS    = %i[properties required additionalProperties].freeze
        COMPOSITE_SCHEMA_KEYWORDS = %i[oneOf anyOf allOf enum $ref $defs definitions].freeze

        # Canonical tool definition.
        # Ports field vocabulary from Legion::LLM::Types::ToolDefinition. # -- required for Data.define block scope
        ToolDefinition = ::Data.define(:name, :description, :parameters, :source, :metadata) do
          def self.normalize_parameters(parameters)
            empty = { type: 'object', properties: {} }
            return empty if parameters.nil?

            Strict.expect_type!(parameters, [::Hash], self::BUILD_SITE, :parameters) unless parameters.is_a?(::Hash)

            schema = parameters.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
            return empty if schema.empty?
            return schema if schema.key?(:type)
            return schema.merge(type: 'object') if OBJECT_SCHEMA_KEYWORDS.any? { |k| schema.key?(k) }
            return schema if COMPOSITE_SCHEMA_KEYWORDS.any? { |k| schema.key?(k) }

            { type: 'object', properties: schema }
          end

          # Build from keyword args (primary constructor).
          def self.build(name:, description: '', parameters: nil, source: nil, metadata: {})
            new(
              sanitize_tool_name(name),
              Strict.expect_type!(description, [::String], self::BUILD_SITE, :description).to_s,
              normalize_parameters(parameters),
              source || { type: :builtin },
              Strict.metadata!(metadata, self::BUILD_SITE)
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          # Canonical keys only (O03a): edges pass `parameters`, not `input_schema`.
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(
              name: hash[:name],
              description: hash[:description],
              parameters: hash[:parameters],
              source: hash[:source],
              metadata:
            )
          end

          # Sanitize a tool name to be safe for all wire formats.
          def self.sanitize_tool_name(raw)
            name = raw.to_s.tr('.', '_')
            name = name.gsub(/[^a-zA-Z0-9_-]/, '')
            name = name[0, TOOL_NAME_MAX_LENGTH] if name.length > TOOL_NAME_MAX_LENGTH
            name.empty? ? 'tool' : name
          end

          def params_schema
            parameters
          end

          def input_schema
            parameters
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            super.compact
          end

          # MultiJson/Oj/::JSON callback — prevents Data.define #inspect leak into JSON.
          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
          end
        end

        ToolDefinition::BUILD_SITE = 'Canonical::ToolDefinition.build'
        ToolDefinition::FROM_HASH_SITE = 'Canonical::ToolDefinition.from_hash'
      end
    end
  end
end
