# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Documents the canonical public provider method signatures shared by provider gems.
      module ProviderContract
        REQUIRED_SIGNATURES = {
          chat: [%i[keyreq messages], %i[keyreq model]],
          stream_chat: [%i[keyreq messages], %i[keyreq model]],
          embed: [%i[keyreq text], %i[keyreq model]],
          image: [%i[keyreq prompt], %i[keyreq model]],
          list_models: [%i[key live], %i[keyrest filters]],
          discover_offerings: [%i[key live], %i[key raise_on_unreachable], %i[keyrest filters]],
          health: [%i[key live]],
          count_tokens: [%i[keyreq messages], %i[keyreq model], %i[key params]]
        }.freeze

        # Tools passed to chat/stream_chat must support Canonical::ToolDefinition objects.
        # Providers must not crash on Data.define instances (not Hashes).
        TOOL_SUPPORT_CONTRACT = <<~DOC
          - chat and stream_chat accept keyword `tools:` (Hash<name, tool_object>)
          - tools may be Canonical::ToolDefinition, Hash, or legacy Lex::Llm::Tool
          - Renderers must use Canonical::ToolSchema.extract(tool) for schema access
          - discover_offerings(live: true, raise_on_unreachable: true) raises on transport failure
        DOC
      end
    end
  end
end
