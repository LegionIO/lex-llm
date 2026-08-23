# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Transport
        # Shared RabbitMQ live-work lane construction for provider fleet
        # workers. The queue defaults live in ONE home — Llm.default_settings
        # (10 U10: no inline literal defaults).
        module FleetLane
          module_function

          def queue_defaults
            Legion::Extensions::Llm.default_settings.dig(:fleet, :consumer) || {}
          end

          def queue_options(settings = {})
            config = queue_defaults.merge((settings || {}).compact.transform_keys(&:to_sym))
            {
              durable: true,
              auto_delete: false,
              arguments: queue_arguments(config)
            }
          end

          def queue_arguments(config)
            {
              'x-queue-type' => 'quorum',
              'x-queue-leader-locator' => 'balanced',
              'x-expires' => config.fetch(:queue_expires_ms),
              'x-message-ttl' => config.fetch(:message_ttl_ms),
              'x-overflow' => 'reject-publish',
              'x-max-length' => config.fetch(:queue_max_length),
              'x-delivery-limit' => config.fetch(:delivery_limit),
              'x-consumer-timeout' => config.fetch(:consumer_ack_timeout_ms)
            }
          end

          def build_queue_class(queue_name:, exchange_class:, routing_key: queue_name, base_queue_class: nil,
                                settings: {})
            parent = base_queue_class || legion_queue_class
            unless parent
              raise ArgumentError,
                    'base_queue_class is required when Legion::Transport::Queue is not loaded'
            end

            options = queue_options(settings)
            Class.new(parent) do
              define_method(:queue_name) { queue_name }
              define_method(:queue_options) { options }
              define_method(:dlx_enabled) { false }
              define_method(:initialize) do
                super()
                bind(exchange_class.new, routing_key: routing_key)
              end
            end
          end

          def legion_queue_class
            return nil unless defined?(::Legion::Transport::Queue)

            ::Legion::Transport::Queue
          end
        end
      end
    end
  end
end
