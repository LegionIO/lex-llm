# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Documents the canonical public provider method signatures shared by provider gems.
      module ProviderContract
        REQUIRED_SIGNATURES = {
          chat: [%i[req messages], %i[keyreq model]],
          stream_chat: [%i[req messages], %i[keyreq model]],
          embed: [%i[keyreq text], %i[keyreq model]],
          image: [%i[keyreq prompt], %i[keyreq model]],
          list_models: [%i[key live], %i[keyrest filters]],
          discover_offerings: [%i[key live], %i[key raise_on_unreachable], %i[keyrest filters]],
          health: [%i[key live]],
          count_tokens: [%i[keyreq messages], %i[keyreq model], %i[key params]]
        }.freeze

        # H3: the tools half of the dispatch boundary contract. A non-empty
        # `tools:` value must be Hash<name, Canonical::ToolDefinition>; the
        # base funnel enforces it once (08 F2) and non-canonical tool values
        # raise ArgumentError. Renderers consume Canonical::ToolDefinition
        # only (schema access via Canonical::ToolSchema); Hash and legacy
        # Lex::Llm::Tool tolerance is deleted from the contract.
        TOOL_SUPPORT_CONTRACT = <<~DOC
          - chat and stream_chat accept keyword `tools:` (Hash<name, Canonical::ToolDefinition> or nil)
          - the base funnel enforces the tool contract once (08 F2): a non-Hash or
            non-ToolDefinition tool value raises ArgumentError before any rendering
          - Renderers must use Canonical::ToolSchema.extract(tool) for schema access
        DOC

        # H5: the read-path contract, stated as implemented. The two base
        # read paths perform different amounts of transport and say so.
        READ_PATH_CONTRACT = <<~DOC
          - list_models: the base read path ALWAYS performs a live HTTP fetch
            (models_url) — it has no non-live view. `live:` is accepted for
            signature compatibility and has no effect in the base. `filters`
            (model/id/name/instance/provider) select from the parsed list.
          - discover_offerings: the base read path serves the SSOT registry
            snapshot for this provider instance — NO transport occurs.
            `live:` and `raise_on_unreachable:` are accepted for signature
            compatibility and have no effect in the base (there is nothing
            that can become unreachable). `filters` select from the snapshot.
          - Provider gems that override either path with a live fetch MUST
            implement `live:` and (for discover_offerings)
            `raise_on_unreachable:` for real — the base guarantees are not
            inherited semantics.
        DOC
      end
    end
  end
end
