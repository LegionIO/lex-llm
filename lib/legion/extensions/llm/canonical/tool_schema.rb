# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Canonical
        # Extracts and normalizes tool schemas from heterogeneous sources.
        module ToolSchema
          EMPTY_OBJECT = { type: 'object', properties: {} }.freeze

          module_function

          def extract(tool)
            raw = raw_schema(tool)
            ToolDefinition.normalize_parameters(raw)
          end

          def raw_schema(tool)
            return nil if tool.nil?
            return tool.params_schema if tool.respond_to?(:params_schema) && tool.params_schema
            return tool.parameters if tool.respond_to?(:parameters) && tool.parameters

            return unless tool.respond_to?(:[])

            tool[:parameters] || tool['parameters'] || tool[:input_schema] || tool['input_schema'] ||
              tool[:params_schema] || tool['params_schema']
          end

          def tool_name(tool)
            return tool.name if tool.respond_to?(:name) && !tool.is_a?(Hash)
            return tool[:name] || tool['name'] if tool.respond_to?(:[])

            'unknown'
          end

          def tool_description(tool)
            return tool.description if tool.respond_to?(:description) && !tool.is_a?(Hash)
            return (tool[:description] || tool['description'] || '').to_s if tool.respond_to?(:[])

            ''
          end
        end
      end
    end
  end
end
