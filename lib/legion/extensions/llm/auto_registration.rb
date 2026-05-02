# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Mixin that lex-llm-* provider modules `extend` to get shared
      # registration boilerplate.  The provider only needs to override
      # `discover_instances` — everything else is handled here.
      #
      # Prerequisites on the extending module:
      #   - `PROVIDER_FAMILY` constant (Symbol, e.g. :ollama)
      #   - `provider_class` singleton method returning the Provider subclass
      module AutoRegistration
        # Override in each provider.  Returns { instance_id => config_hash }.
        def discover_instances
          {}
        end

        # Calls discover_instances, creates a LexLLMAdapter for each,
        # and registers into Call::Registry.
        #
        # Strips :tier and :capabilities from config before passing to
        # the adapter (these are metadata, not connection config).
        #
        # Guarded: no-op when Legion::LLM::Call::Registry is not loaded.
        def register_discovered_instances
          return unless defined?(Legion::LLM::Call::Registry)

          instances = discover_instances
          instances.each do |instance_id, config|
            registry_config = config.except(:tier, :capabilities)
            adapter = Legion::LLM::Call::LexLLMAdapter.new(
              self::PROVIDER_FAMILY, provider_class, instance_config: registry_config
            )
            meta = { tier: config[:tier], capabilities: config[:capabilities] || [] }
            Legion::LLM::Call::Registry.register(
              self::PROVIDER_FAMILY, adapter, instance: instance_id, metadata: meta
            )
          end
        rescue StandardError => e
          log.warn "[#{self::PROVIDER_FAMILY}] self-registration failed: #{e.message}" if respond_to?(:log)
        end

        # Deregisters all instances for this provider and re-runs discovery.
        #
        # Guarded: no-op when Legion::LLM::Call::Registry is not loaded.
        def rediscover!
          return unless defined?(Legion::LLM::Call::Registry)

          Legion::LLM::Call::Registry.deregister_provider(self::PROVIDER_FAMILY)
          register_discovered_instances
        end
      end
    end
  end
end
