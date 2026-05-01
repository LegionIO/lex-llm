# frozen_string_literal: true

return unless defined?(Legion::Transport::Message)

require_relative '../exchanges/llm_registry'

module Legion
  module Extensions
    module Llm
      module Transport
        module Messages
          # Publishes lex-llm RegistryEvent envelopes to the shared llm.registry exchange.
          # Accepts a `provider_family` for constructing the app_id and routing key.
          class RegistryEvent < ::Legion::Transport::Message
            def initialize(event:, provider_family: nil, **options)
              @provider_family = provider_family
              super(**event.to_h.merge(options))
            end

            def exchange
              Exchanges::LlmRegistry
            end

            def routing_key
              @options[:routing_key] || "llm.registry.#{@options.fetch(:event_type)}"
            end

            def type
              'llm.registry.event'
            end

            def app_id
              @options[:app_id] || "lex-llm-#{@provider_family || 'unknown'}"
            end

            def persistent # rubocop:disable Naming/PredicateMethod
              false
            end
          end
        end
      end
    end
  end
end
