# frozen_string_literal: true

require_relative 'canonical/thinking'
require_relative 'canonical/usage'
require_relative 'canonical/params'
require_relative 'canonical/content_block'
require_relative 'canonical/tool_definition'
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

        # Available canonical types.
        TYPES = %i[
          Thinking Usage Params ContentBlock
          ToolDefinition ToolCall Message
          Request Response Chunk
        ].freeze

        class << self
          # List all canonical type classes.
          def types
            TYPES.map { |name| const_get(name) }
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
