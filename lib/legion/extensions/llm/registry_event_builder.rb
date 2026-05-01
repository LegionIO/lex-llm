# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Builds sanitized lex-llm registry envelopes for provider state.
      # Parameterized by `provider_family` so each lex-llm-* gem can reuse this
      # class without defining its own copy.
      class RegistryEventBuilder
        include Legion::Logging::Helper

        attr_reader :provider_family

        def initialize(provider_family:)
          @provider_family = provider_family.to_s.downcase.to_sym
        end

        def readiness(readiness)
          registry_event_class.public_send(
            readiness[:ready] ? :available : :unavailable,
            provider_offering(readiness),
            runtime: runtime_metadata,
            health: readiness_health(readiness),
            metadata: readiness_metadata(readiness)
          )
        end

        def model_available(model, readiness:)
          registry_event_class.available(
            model_offering(model),
            runtime: runtime_metadata,
            health: model_health(readiness),
            metadata: model_metadata(model)
          )
        end

        private

        def provider_offering(readiness)
          {
            provider_family: provider_family,
            provider_instance: provider_instance,
            transport: :http,
            model: 'provider-readiness',
            usage_type: :inference,
            capabilities: [],
            health: readiness_health(readiness),
            metadata: { lex: extension_sym, provider_readiness: true }
          }
        end

        def model_offering(model)
          {
            provider_family: provider_family,
            provider_instance: provider_instance,
            transport: :http,
            model: model.id,
            usage_type: usage_type_for(model),
            capabilities: Array(model.capabilities).map(&:to_sym),
            limits: model_limits(model),
            metadata: { lex: extension_sym, model_name: model.name }.compact
          }
        end

        def readiness_health(readiness)
          health = {
            ready: readiness[:ready] == true,
            status: readiness[:ready] ? :available : :unavailable,
            checked: readiness.dig(:health, :checked) != false
          }
          add_readiness_error(health, readiness[:health])
        end

        def add_readiness_error(health, source)
          error = source.is_a?(Hash) ? source : {}
          error_class = error[:error] || error['error']
          error_message = error[:message] || error['message']
          health[:error_class] = error_class if error_class
          health[:error] = error_message if error_message
          health
        end

        def model_health(readiness)
          ready = readiness.fetch(:ready, true) == true
          { ready:, status: ready ? :available : :degraded }
        end

        def readiness_metadata(readiness)
          {
            extension: extension_sym,
            provider: provider_family,
            configured: readiness[:configured] == true,
            live: readiness[:live] == true
          }
        end

        def model_metadata(model)
          { extension: extension_sym, provider: provider_family, model_type: model_type_for(model) }
        end

        def runtime_metadata
          { node: provider_instance }
        end

        def model_limits(model)
          limits = {}
          limits[:context_window] = model.context_window if model.respond_to?(:context_window)
          limits[:max_output_tokens] = model.max_output_tokens if model.respond_to?(:max_output_tokens)
          limits.compact
        end

        def usage_type_for(model)
          model_type_for(model) == 'embedding' ? :embedding : :inference
        end

        def model_type_for(model)
          model.respond_to?(:type) ? model.type : 'chat'
        end

        def extension_sym
          :"llm_#{provider_family}"
        end

        def provider_instance
          configured_node = (::Legion::Settings.dig(:node, :canonical_name) if defined?(::Legion::Settings))
          value = configured_node.to_s.strip
          value.empty? ? provider_family : value.to_sym
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true,
                              operation: "#{provider_family}.registry.provider_instance")
          provider_family
        end

        def registry_event_class
          ::Legion::Extensions::Llm::Routing::RegistryEvent
        end
      end
    end
  end
end
