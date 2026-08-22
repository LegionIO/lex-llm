# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Mixin that lex-llm-* provider modules `extend` to expose shared
      # discovery metadata. Registration into Legion::LLM is owned by
      # legion-llm so loaded providers can be rediscovered after reloads.
      #
      # Prerequisites on the extending module:
      #   - `PROVIDER_FAMILY` constant (Symbol, e.g. :ollama)
      #   - `provider_class` singleton method returning the Provider subclass
      #
      # The legacy discover_instances/provider_aliases defaults are deleted
      # (Phase 4): providers define their own instance discovery, and
      # publication goes through Inventory::Publisher directly.
      module AutoRegistration
      end
    end
  end
end
