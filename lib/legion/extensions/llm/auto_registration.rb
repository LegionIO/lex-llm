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
      # DEPRECATED (Phase 4 removal): discover_instances/provider_aliases are kept
      # for old consumers; no new registration side effect is added here. Migrated
      # provider actors use Inventory::Publisher directly.
      module AutoRegistration
        # Override in each provider.  Returns { instance_id => config_hash }.
        def discover_instances
          {}
        end

        # Optional provider-family aliases that legion-llm should register
        # against the same discovered provider instances.
        def provider_aliases
          []
        end
      end
    end
  end
end
