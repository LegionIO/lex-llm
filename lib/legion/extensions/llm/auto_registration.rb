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
            normalized_config = normalize_instance_config(config)
            registry_config = adapter_instance_config(normalized_config, instance_id)
            adapter = Legion::LLM::Call::LexLLMAdapter.new(
              self::PROVIDER_FAMILY, provider_class, instance_config: registry_config
            )
            meta = { tier: normalized_config[:tier], capabilities: normalized_config[:capabilities] || [] }
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

        private

        def normalize_instance_config(config)
          config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        end

        def adapter_instance_config(config, instance_id)
          config.except(:tier, :capabilities).tap do |registry_config|
            registry_config[:instance_id] ||= instance_id
          end
        end
      end
    end
  end
end
