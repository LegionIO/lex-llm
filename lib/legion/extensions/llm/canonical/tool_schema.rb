# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Canonical
        # Extracts and normalizes tool schemas from ToolDefinition ONLY (04 §6).
        # A schema extractor that tolerates raw hashes is a hidden path over the
        # canonical type — wrong-class input raises (L3).
        module ToolSchema
          EMPTY_OBJECT = { type: 'object', properties: {} }.freeze

          module_function

          def extract(tool_definition)
            require_tool_definition!(tool_definition, 'ToolSchema.extract')
            ToolDefinition.normalize_parameters(tool_definition.parameters)
          end

          def tool_name(tool_definition)
            require_tool_definition!(tool_definition, 'ToolSchema.tool_name')
            tool_definition.name
          end

          def tool_description(tool_definition)
            require_tool_definition!(tool_definition, 'ToolSchema.tool_description')
            tool_definition.description
          end

          def require_tool_definition!(tool_definition, site)
            return tool_definition if tool_definition.is_a?(ToolDefinition)

            raise ArgumentError, "#{site}: expected Canonical::ToolDefinition, got #{tool_definition.class}"
          end
        end
      end
    end
  end
end
