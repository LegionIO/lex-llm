# frozen_string_literal: true

require 'legion/extensions/llm/utils'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/routing/provider_outcome'
require_relative 'protocol'
require_relative 'settings'
require_relative 'contract_error'
require_relative 'fleet_envelope'
require_relative 'worker_execution'
require 'legion/extensions/llm/inventory/registry'

module Legion
  module Extensions
    module Llm
      module Transport
        # Autoloads responder publish envelopes without booting legion-transport during lex-llm load.
        module Messages
          autoload :FleetError, File.expand_path('../transport/messages/fleet_error', __dir__) unless
            autoload?(:FleetError) || const_defined?(:FleetError, false)
          autoload :FleetResponse, File.expand_path('../transport/messages/fleet_response', __dir__) unless
            autoload?(:FleetResponse) || const_defined?(:FleetResponse, false)
        end
      end

      module Fleet
        # Shared implementation for provider-owned fleet responder runners.
        # Protocol v3 (06 W9): parse → legacy-field rejection → required fields
        # (one Protocol::REQUIRED_FIELDS list) → explicit version →
        # provider-family match → exact execution contract (required, P2) →
        # WorkerExecution.call → publish FleetResponse (E3/E4) → ack. On error:
        # publish FleetError (E6), reject per F6, re-raise.
        module ProviderResponder
          include Legion::Logging::Helper
          extend Legion::Logging::Helper

          class ConfigurationError < StandardError; end

          module_function

          # Public runner entry point mirrors AMQP delivery callbacks, which carry both delivery and property metadata.
          # L6: the dead provider_class/provider_instances params are deleted —
          # v3 dispatch is exact-only and never constructs a provider; passing
          # provider objects here was a latent second execution truth.
          def call(payload:, provider_family:,
                   registry: ::Legion::Extensions::Llm::Inventory::Registry, delivery: nil, properties: nil)
            envelope = parse_payload(payload)
            check_envelope!(envelope, provider_family:)
            response = WorkerExecution.call(envelope: envelope, registry:)
            publish_response(envelope, response)
            ack(delivery || properties)
            response
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: false, operation: 'llm.fleet.provider_responder.call',
                                provider_family:)
            safe_publish_error(envelope, e) if defined?(envelope) && envelope
            reject(delivery || properties, requeue: requeue_error?(e))
            raise
          end

          def enabled_for?(provider_instances)
            instances = resolve_provider_instances(provider_instances)
            instances.any? do |_instance_id, settings|
              truthy?(Utils.deep_symbolize_keys(settings).dig(:fleet, :respond_to_requests))
            end
          end

          # E1: the single wire-normalization entry. Wrong-shape payloads
          # (neither Hash, String, nor envelope) raise — the silent {} fallback
          # is deleted.
          def parse_payload(payload)
            case payload
            when FleetEnvelope then payload
            when String then FleetEnvelope.new(data: parse_json(payload))
            when Hash then FleetEnvelope.new(data: payload)
            else
              raise ContractError, "fleet payload expected Hash or String, got #{payload.class}"
            end
          end

          def check_envelope!(envelope, provider_family:)
            reject_legacy_fields!(envelope)
            Protocol::REQUIRED_FIELDS.each do |field|
              raise ArgumentError, "#{field} is required" unless envelope.key?(field) && !envelope[field].nil?
            end

            validate_protocol_version!(envelope)
            validate_provider_family!(envelope, provider_family)
            validate_execution_contract!(envelope)
          end

          # P2: exact execution only — the marker is required and must equal
          # the exact marker; absence is rejected. The exact fields are
          # additionally required by the marker.
          def validate_execution_contract!(envelope)
            marker = envelope.execution_contract
            raise ContractError, "execution_contract must be #{Protocol::EXACT_EXECUTION_CONTRACT}" unless
              marker == Protocol::EXACT_EXECUTION_CONTRACT

            Protocol::EXACT_REQUIRED_FIELDS.each do |field|
              raise ContractError, "#{field} is required for #{Protocol::EXACT_EXECUTION_CONTRACT}" unless envelope.key?(field) && !envelope[field].nil?
            end
          end

          # E3: the response envelope carries the serialized Canonical::Response.
          # E4/G5: thinking never crosses the fleet — excluded exactly once, here.
          def publish_response(envelope, response)
            transport_message_class(:FleetResponse).new(
              protocol_version: envelope.protocol_version,
              request_id: envelope.request_id,
              correlation_id: envelope.correlation_id,
              idempotency_key: envelope.idempotency_key,
              operation: envelope.operation,
              provider: envelope.provider,
              provider_instance: envelope.provider_instance,
              model: envelope.model,
              reply_to: envelope.reply_to,
              message_context: envelope.message_context,
              trace_context: envelope.trace_context,
              response: response.to_h.except(:thinking),
              execution_contract: envelope.execution_contract,
              offering_id: envelope.offering_id
            ).publish
          end

          # E6: the error envelope. retryable is derived per F6.
          def publish_error(envelope, error)
            transport_message_class(:FleetError).new(
              protocol_version: envelope.protocol_version,
              request_id: envelope.request_id,
              correlation_id: envelope.correlation_id,
              idempotency_key: envelope.idempotency_key,
              operation: envelope.operation,
              provider: envelope.provider,
              provider_instance: envelope.provider_instance,
              model: envelope.model,
              reply_to: envelope.reply_to,
              message_context: envelope.message_context,
              trace_context: envelope.trace_context,
              code: error_code(error),
              message: error.message,
              error_class: error.class.name,
              retryable: retryable_error?(error),
              metadata: {},
              execution_contract: envelope.execution_contract,
              offering_id: envelope.offering_id
            ).publish
          end

          def safe_publish_error(envelope, error)
            publish_error(envelope, error)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true,
                                operation: 'llm.fleet.provider_responder.safe_publish_error',
                                error_class: error.class.name)
            nil
          end

          def transport_message_class(name)
            ::Legion::Extensions::Llm::Transport::Messages.const_get(name)
          rescue LoadError, NameError => e
            raise ConfigurationError, "fleet responder transport unavailable for #{name}: #{e.message}"
          end

          def ack(delivery)
            return unless delivery

            if delivery.respond_to?(:ack)
              delivery.ack
            elsif delivery.respond_to?(:channel) && delivery.respond_to?(:delivery_tag)
              delivery.channel.ack(delivery.delivery_tag)
            end
          end

          def reject(delivery, requeue:)
            return unless delivery

            if delivery.respond_to?(:reject)
              delivery.reject(requeue)
            elsif delivery.respond_to?(:channel) && delivery.respond_to?(:delivery_tag)
              delivery.channel.reject(delivery.delivery_tag, requeue)
            end
          end

          # L1: Legion::JSON only (house rule) — the bare ::JSON fallback is
          # deleted; Legion::JSON is a hard dependency of this gem.
          def parse_json(payload)
            ::Legion::JSON.parse(payload)
          end

          def reject_legacy_fields!(envelope)
            Protocol::LEGACY_FIELDS.each do |field|
              raise ArgumentError, "#{field} is not supported by fleet protocol v3" if envelope.key?(field)
            end
          end

          # P3: explicit version — no default fill.
          def validate_protocol_version!(envelope)
            return if envelope.protocol_version == Protocol::VERSION

            raise ArgumentError, "protocol_version must be #{Protocol::VERSION}"
          end

          def validate_provider_family!(envelope, provider_family)
            return if envelope.provider.to_s == provider_family.to_s

            raise ArgumentError, "fleet request provider #{envelope.provider} does not match #{provider_family}"
          end

          def resolve_provider_instances(provider_instances)
            instances = provider_instances.respond_to?(:call) ? provider_instances.call : provider_instances
            Utils.deep_symbolize_keys(instances || {})
          end

          def requeue_error?(error)
            retryable_error?(error) &&
              Settings.value(:fleet, :consumer, :requeue_transient, default: true) != false
          end

          # F6: retryability is derived from the one ProviderOutcome kind table
          # (05 O6) — transient kinds retry; contract/policy/auth/classification
          # kinds never do. The default-true catch-all is deleted.
          def retryable_error?(error)
            return false if error.is_a?(ConfigurationError)
            return false if error.is_a?(WorkerExecution::PolicyError)
            return false if error.is_a?(ContractError)
            return false if error.is_a?(TokenError)
            return false if error.is_a?(Inventory::Errors::ExactOfferingMismatchError)

            ::Legion::Extensions::Llm::Routing::ProviderOutcome::RETRYABLE_KINDS.include?(
              ::Legion::Extensions::Llm::Routing::ProviderOutcome.kind_for(error)
            )
          end

          def error_code(error)
            return 'configuration_error' if error.is_a?(ConfigurationError)
            return 'policy_error' if error.is_a?(WorkerExecution::PolicyError)
            return 'contract_error' if error.is_a?(ContractError)

            'provider_error'
          end

          def truthy?(value)
            value == true || value.to_s == 'true'
          end
        end
      end
    end
  end
end
