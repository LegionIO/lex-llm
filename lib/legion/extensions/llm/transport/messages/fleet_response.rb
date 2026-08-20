# frozen_string_literal: true

require 'securerandom'
require_relative '../../fleet/default_exchange_reply'
require_relative '../../fleet/envelope_validation'
require_relative '../../fleet/protocol'
require_relative '../exchanges/fleet'

module Legion
  module Extensions
    module Llm
      module Transport
        module Messages
          # Correlated protocol-v3 response envelope for fleet reply queues.
          # E3: carries the serialized Canonical::Response under :response.
          # E4: thinking exclusion happens exactly once at the responder
          # (ProviderResponder#publish_response); this envelope is a pass-through.
          # E5: no aliases — provider_instance only.
          class FleetResponse < ::Legion::Transport::Message
            include Fleet::DefaultExchangeReply
            include Fleet::EnvelopeValidation

            def type = Fleet::Protocol::RESPONSE_TYPE
            def encrypt? = Fleet::Settings.value(:fleet, :compliance, :encrypt_fleet, default: true) == true
            def app_id = @options[:app_id] || 'lex-llm'
            def reply_to = @options[:reply_to]
            def correlation_id = @options[:correlation_id]
            def message_id = @options[:message_id] ||= "llm_fleet_res_#{SecureRandom.uuid}"

            def routing_key
              @options[:reply_to] || raise(ArgumentError, 'reply_to is required')
            end

            def validate
              reject_legacy_options!
              require_option!(:request_id)
              require_option!(:correlation_id)
              require_option!(:reply_to)
              require_option!(:response)
              require_protocol_version!
              @valid = true
            end

            def message
              super.merge(
                protocol_version: @options[:protocol_version],
                request_id: @options[:request_id],
                correlation_id: correlation_id,
                idempotency_key: @options[:idempotency_key],
                operation: @options[:operation],
                provider: @options[:provider],
                provider_instance: @options[:provider_instance],
                model: @options[:model],
                reply_to: reply_to,
                message_context: @options[:message_context],
                trace_context: @options[:trace_context],
                response: @options[:response],
                execution_contract: @options[:execution_contract],
                offering_id: @options[:offering_id]
              ).compact
            end
          end
        end
      end
    end
  end
end
