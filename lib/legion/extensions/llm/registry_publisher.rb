# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Best-effort publisher for LLM provider availability events.
      # Parameterized by `provider_family` so each lex-llm-* gem can reuse this
      # class without defining its own copy.
      class RegistryPublisher
        include Legion::Logging::Helper

        attr_reader :provider_family

        def initialize(provider_family:, builder: nil)
          @provider_family = provider_family.to_s.downcase.to_sym
          @builder = builder || RegistryEventBuilder.new(provider_family: @provider_family)
        end

        def app_id
          "lex-llm-#{provider_family}"
        end

        def publish_readiness_async(readiness)
          log.info { "publishing readiness event to llm.registry for #{provider_family}" }
          schedule { publish_event(@builder.readiness(readiness)) }
        end

        def publish_models_async(models, readiness:)
          log.info { "publishing #{Array(models).size} model event(s) to llm.registry for #{provider_family}" }
          schedule do
            Array(models).each do |model|
              publish_event(@builder.model_available(model, readiness:))
            end
          end
        end

        private

        def schedule(&)
          return false unless publishing_available?

          Thread.new do
            Thread.current.abort_on_exception = false
            yield
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true,
                                operation: "#{provider_family}.registry.schedule_thread")
          end
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true,
                              operation: "#{provider_family}.registry.schedule")
          false
        end

        def publish_event(event)
          return false unless publishing_available?

          message_class.new(event:, provider_family: provider_family, app_id: app_id).publish(spool: false)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: "#{provider_family}.registry.publish_event")
          false
        end

        def publishing_available?
          return false unless registry_event_available?
          return false unless transport_message_available?
          return true unless defined?(::Legion::Transport::Connection)
          return true unless ::Legion::Transport::Connection.respond_to?(:session_open?)

          ::Legion::Transport::Connection.session_open?
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true,
                              operation: "#{provider_family}.registry.publishing_available?")
          false
        end

        def registry_event_available?
          defined?(::Legion::Extensions::Llm::Routing::RegistryEvent)
        end

        def transport_message_available?
          return true if message_class_defined?
          return false unless defined?(::Legion::Transport::Message) && defined?(::Legion::Transport::Exchange)

          require 'legion/extensions/llm/transport/messages/registry_event'
          message_class_defined?
        rescue LoadError => e
          handle_exception(e, level: :debug, handled: true,
                              operation: "#{provider_family}.registry.transport_load")
          false
        end

        def message_class_defined?
          defined?(::Legion::Extensions::Llm::Transport::Messages::RegistryEvent)
        end

        def message_class
          ::Legion::Extensions::Llm::Transport::Messages::RegistryEvent
        end
      end
    end
  end
end
