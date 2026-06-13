# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Canonical
        TOOL_NAME_MAX_LENGTH = 64

        # Canonical tool definition.
        # Ports field vocabulary from Legion::LLM::Types::ToolDefinition.
        ToolDefinition = ::Data.define(:name, :description, :parameters, :source) do
          OBJECT_SCHEMA_KEYWORDS    = %i[properties required additionalProperties].freeze
          COMPOSITE_SCHEMA_KEYWORDS = %i[oneOf anyOf allOf enum $ref $defs definitions].freeze

          def self.normalize_parameters(parameters)
            empty = { type: 'object', properties: {} }
            return empty if parameters.nil?

            schema = if parameters.respond_to?(:transform_keys)
                       parameters.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
                     end
            return empty if schema.nil? || schema.empty?
            return schema if schema.key?(:type)
            return schema.merge(type: 'object') if OBJECT_SCHEMA_KEYWORDS.any? { |k| schema.key?(k) }
            return schema if COMPOSITE_SCHEMA_KEYWORDS.any? { |k| schema.key?(k) }

            { type: 'object', properties: schema }
          end

          # Build from keyword args (primary constructor).
          def self.build(name:, description: '', parameters: nil, source: nil)
            new(
              sanitize_tool_name(name),
              description.to_s,
              normalize_parameters(parameters),
              source || { type: :builtin }
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          def self.from_hash(hash, source: nil)
            return nil if hash.nil?

            normalized = hash.respond_to?(:transform_keys) ? hash.transform_keys(&:to_sym) : {}
            build(
              name: normalized[:name],
              description: normalized[:description],
              parameters: normalized[:parameters] || normalized[:input_schema],
              source: source || normalized[:source]
            )
          end

          # Build from a registry entry (extension/registry tool metadata).
          def self.from_registry_entry(entry)
            source = {
              type: entry[:tool_class] ? :registry : :extension,
              tool_class: entry[:tool_class],
              extension: entry[:extension],
              runner: entry[:runner],
              function: entry[:function]
            }.compact

            build(
              name: entry[:name],
              description: entry[:description],
              parameters: entry[:input_schema] || entry[:parameters],
              source: source.compact
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
            {
              name: name,
              description: description,
              parameters: parameters
            }.compact.reject { |k, v| k == :description && v == '' }
          end
        end
      end
    end
  end
end
