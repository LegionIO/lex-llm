# frozen_string_literal: true

require 'securerandom'
require_relative '../../fleet/envelope_validation'
require_relative '../../fleet/publish_safety'
require_relative '../../fleet/protocol'
require_relative '../exchanges/fleet'

module Legion
  module Extensions
    module Llm
      module Transport
        module Messages
          # Strict protocol-v2 request envelope for outbound fleet work.
          class FleetRequest < ::Legion::Transport::Message
            include Fleet::EnvelopeValidation
            include Fleet::PublishSafety

            PRIORITY_MAP = { critical: 9, high: 7, normal: 5, low: 2 }.freeze
            DEFAULT_PUBLISH_OPTIONS = {
              mandatory: true,
              publisher_confirm: true,
              spool: false,
              return_result: true
            }.freeze
            REQUIRED_OPTIONS = %i[
              request_id correlation_id operation provider provider_instance model params reply_to
              message_context caller trace_context signed_token timeout_seconds expires_at protocol_version
              idempotency_key
            ].freeze

            def exchange = Exchanges::Fleet
            def type = Fleet::Protocol::REQUEST_TYPE
            def app_id = @options[:app_id] || 'lex-llm'
            def reply_to = @options[:reply_to]
            def correlation_id = @options[:correlation_id]
            def message_id = @options[:message_id] ||= "llm_fleet_req_#{SecureRandom.uuid}"

            def priority
              PRIORITY_MAP.fetch(@options[:priority].to_sym, 5) if @options[:priority]
            end

            def routing_key
              @options[:routing_key] || raise(ArgumentError, 'routing_key is required')
            end

            def expiration
              ttl = @options[:ttl] || @options[:timeout_seconds]
              return super unless ttl

              (Float(ttl) * 1000).ceil.to_s
            rescue ArgumentError, TypeError
              super
            end

            def publish(options = nil)
              raise unless @valid

              requested_options = DEFAULT_PUBLISH_OPTIONS.merge(@options).merge(options || {})
              return_result = return_publish_result?(requested_options)
              publish_options = request_publish_options(requested_options)
              validate_payload_size
              exchange_dest = fleet_exchange
              return_state = {}
              install_return_listener(exchange_dest, requested_options, return_state)
              prepare_publisher_confirms(exchange_dest, requested_options)
              exchange_dest.publish(encode_message, **publish_options)
              return nil unless return_result

              publish_result(exchange_dest, requested_options.merge(publish_options), return_state)
            rescue Bunny::ConnectionClosedError, Bunny::ChannelAlreadyClosed, Bunny::ChannelError,
                   Bunny::NetworkErrorWrapper, IOError, Timeout::Error => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.fleet.request.publish')
              publish_failure_result(:failed, e, publish_options || requested_options || @options)
            end

            def validate
              reject_legacy_options!
              require_option!(:routing_key)
              REQUIRED_OPTIONS.each { |key| require_option!(key) }
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
                params: @options[:params] || {},
                reply_to: reply_to,
                message_context: @options[:message_context],
                caller: @options[:caller],
                trace_context: @options[:trace_context],
                signed_token: @options[:signed_token],
                timeout_seconds: @options[:timeout_seconds],
                expires_at: @options[:expires_at]
              ).compact
            end

            private

            def fleet_exchange
              exchange_class = exchange
              if exchange_class.respond_to?(:cached_instance)
                exchange_class.cached_instance || exchange_class.new
              elsif exchange_class.respond_to?(:new)
                exchange_class.new
              else
                exchange_class
              end
            end

            def request_publish_options(options)
              request_publish_envelope(options).tap do |envelope|
                envelope[:mandatory] = true if options[:mandatory] == true
              end.compact
            end

            def request_publish_envelope(options)
              {
                routing_key: routing_key || '',
                content_type: options[:content_type] || content_type,
                content_encoding: options[:content_encoding] || content_encoding,
                type: options[:type] || type,
                priority: options[:priority] || priority,
                expiration: options[:expiration] || expiration,
                headers: request_headers(options),
                persistent: request_persistent(options),
                message_id: message_id,
                correlation_id: correlation_id,
                reply_to: reply_to,
                app_id: options[:app_id] || app_id,
                timestamp: timestamp
              }
            end

            def request_headers(options)
              options[:headers] ? headers.merge(options[:headers]) : headers
            end

            def request_persistent(options)
              options.key?(:persistent) ? options[:persistent] : persistent
            end
          end
        end
      end
    end
  end
end
