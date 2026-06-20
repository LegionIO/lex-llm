# frozen_string_literal: true

require_relative '../capabilities'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Inventory-side capability normalization. Every per-gem DiscoveryRefresh actor
        # calls this from `lanes_from_instance` to coerce offering capabilities into a
        # canonical symbol list before writing the lane to Inventory. Without this
        # constant, every actor's guard `return [] unless defined?(...)` fires and the
        # lane is written with `capabilities: []` — even when the operator declared
        # `enable_tools: true` / `enable_thinking: true` on the instance and the
        # provider's CapabilityPolicy correctly resolved them in the offering.
        #
        # Delegates to Legion::Extensions::Llm::Capabilities so the alias table
        # (function_calling/tool_use/tool_calls/tool/functions → tools, etc.) stays
        # in one place.
        module Capabilities
          ALIASES = Legion::Extensions::Llm::Capabilities::ALIASES

          module_function

          def normalize(caps, **)
            Legion::Extensions::Llm::Capabilities.normalize(caps, **)
          end

          def merge(*sets, **)
            Legion::Extensions::Llm::Capabilities.merge(*sets, **)
          end

          def include_all?(available, required, **)
            Legion::Extensions::Llm::Capabilities.include_all?(available, required, **)
          end
        end
      end
    end
  end
end
