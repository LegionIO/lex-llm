# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Canonical
        OBJECT_SCHEMA_KEYWORDS    = %i[properties required additionalProperties].freeze
        COMPOSITE_SCHEMA_KEYWORDS = %i[oneOf anyOf allOf enum $ref $defs definitions].freeze

        # Canonical tool definition.
        # Ports field vocabulary from Legion::LLM::Types::ToolDefinition. # -- required for Data.define block scope
        ToolDefinition = ::Data.define(:name, :description, :parameters, :source, :metadata) do
          def self.normalize_parameters(parameters)
            empty = { type: 'object', properties: {} }
            return empty if parameters.nil?

            Strict.expect_type!(parameters, [::Hash], self::NORMALIZE_PARAMETERS_SITE, :parameters) unless parameters.is_a?(::Hash)

            schema = parameters.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
            return empty if schema.empty?
            return schema if schema.key?(:type)
            return schema.merge(type: 'object') if OBJECT_SCHEMA_KEYWORDS.any? { |k| schema.key?(k) }
            return schema if COMPOSITE_SCHEMA_KEYWORDS.any? { |k| schema.key?(k) }

            { type: 'object', properties: schema }
          end

          # Build from keyword args (primary constructor). M5: the name is the
          # authoritative client/registry fact — never rewritten, stripped,
          # truncated, or fabricated here; per-dialect name constraints belong
          # to the provider translator edge. source is explicit or absent —
          # never fabricated ({ type: :builtin } is deleted).
          def self.build(name:, description: '', parameters: nil, source: nil, metadata: {})
            new(
              name,
              description,
              normalize_parameters(parameters),
              source,
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

          # M5: a tool name is authoritative — missing or empty is a contract
          # error, never a fabricated label.
          def self.require_name!(name, site)
            raise ArgumentError, "#{site}: name must be a non-empty String, got #{name.class}: #{name.inspect}" unless name.is_a?(::String) && !name.empty?

            name
          end

          # M5: description is a String; absence is the empty string (the
          # documented no-description value), wrong class raises.
          def self.description_value!(description, site)
            return '' if description.nil?

            Strict.expect_type!(description, [::String], site, :description)
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

          # H1/M5: the single strict constructor — .new runs the same member
          # contract as the factories (authoritative name, String
          # description, normalized parameters, explicit-or-absent source);
          # the factories fill their defaults and delegate here.
          Strict.install_strict_new!(self) do |values, site|
            values[:name] = require_name!(values[:name], site)
            values[:description] = description_value!(values[:description], site)
            values[:parameters] = normalize_parameters(values[:parameters])
            values[:source] = Strict.expect_type!(values[:source], [::Hash], site, :source)
            values[:metadata] = Strict.metadata!(values[:metadata], site)
            values
          end
        end

        ToolDefinition::BUILD_SITE = 'Canonical::ToolDefinition.build'
        ToolDefinition::FROM_HASH_SITE = 'Canonical::ToolDefinition.from_hash'
        ToolDefinition::NEW_SITE = 'Canonical::ToolDefinition.new'
        ToolDefinition::NORMALIZE_PARAMETERS_SITE = 'Canonical::ToolDefinition.normalize_parameters'
      end
    end
  end
end
