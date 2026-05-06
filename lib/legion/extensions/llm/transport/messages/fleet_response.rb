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
          # Correlated protocol-v2 response envelope for fleet reply queues.
          class FleetResponse < ::Legion::Transport::Message
            include Fleet::DefaultExchangeReply
            include Fleet::EnvelopeValidation

            def type = Fleet::Protocol::RESPONSE_TYPE
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
              require_protocol_version!
              @valid = true
            end

            def message
              super.except(:thinking).merge(
                protocol_version: @options[:protocol_version] || Fleet::Protocol::VERSION,
                request_id: @options[:request_id],
                correlation_id: correlation_id,
                idempotency_key: @options[:idempotency_key],
                operation: @options[:operation],
                provider: @options[:provider],
                provider_instance: @options[:provider_instance] || @options[:instance],
                model: @options[:model],
                reply_to: reply_to,
                message_context: @options[:message_context],
                trace_context: @options[:trace_context],
                content: @options[:content],
                tool_calls: @options[:tool_calls],
                usage: @options[:usage] || {},
                finish_reason: @options[:finish_reason],
                metadata: @options[:metadata] || {}
              ).compact
            end
          end
        end
      end
    end
  end
end
