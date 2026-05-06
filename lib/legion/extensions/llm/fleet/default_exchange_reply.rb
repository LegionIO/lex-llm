# frozen_string_literal: true

require_relative 'publish_safety'

module Legion
  module Extensions
    module Llm
      module Fleet
        # Publishes correlated fleet replies directly to the caller's reply queue.
        module DefaultExchangeReply
          include PublishSafety

          DEFAULT_REPLY_PUBLISH_OPTIONS = {
            mandatory: false,
            publisher_confirm: false,
            spool: false,
            return_result: true
          }.freeze

          def publish(options = nil)
            raise unless @valid

            requested_options = DEFAULT_REPLY_PUBLISH_OPTIONS.merge(@options).merge(options || {})
            return_result = return_publish_result?(requested_options)
            publish_options = reply_publish_options(requested_options)
            validate_payload_size
            default_exchange = channel.default_exchange
            return_state = {}
            install_return_listener(default_exchange, requested_options, return_state)
            prepare_publisher_confirms(default_exchange, requested_options)
            default_exchange.publish(encode_message, **publish_options)
            return nil unless return_result

            publish_result(default_exchange, requested_options.merge(publish_options), return_state)
          rescue Bunny::ConnectionClosedError, Bunny::ChannelAlreadyClosed, Bunny::ChannelError,
                 Bunny::NetworkErrorWrapper, IOError, Timeout::Error => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.fleet.reply.publish')
            reply_publish_failure_result(e, publish_options || @options)
          end

          private

          def reply_publish_failure_result(error, options)
            {
              status: :failed,
              accepted: false,
              error_class: error.class.name,
              error: error.message,
              routing_key: options[:routing_key] || routing_key,
              message_id: message_id,
              correlation_id: correlation_id
            }.compact
          end

          def reply_publish_options(options)
            {
              routing_key: routing_key,
              content_type: options[:content_type] || content_type,
              content_encoding: options[:content_encoding] || content_encoding,
              type: options[:type] || type,
              priority: options[:priority] || priority,
              expiration: options[:expiration] || expiration,
              headers: reply_headers(options),
              persistent: options.key?(:persistent) ? options[:persistent] : persistent,
              message_id: message_id,
              correlation_id: correlation_id,
              reply_to: reply_to,
              app_id: options[:app_id] || app_id,
              timestamp: timestamp,
              mandatory: options[:mandatory] == true
            }.compact
          end

          def reply_headers(options)
            options[:headers] ? headers.merge(options[:headers]) : headers
          end
        end
      end
    end
  end
end
