# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Fleet
        # Publish-result helpers kept local to fleet messages so they work with older legion-transport releases.
        module PublishSafety
          private

          def return_publish_result?(options)
            options[:return_result] == true || options[:mandatory] == true || options[:publisher_confirm] == true ||
              options[:spool] == false
          end

          def install_return_listener(exchange_dest, options, return_state)
            return unless options[:mandatory] == true

            return_channel = publish_channel(exchange_dest)
            return unless return_channel.respond_to?(:on_return)

            expected_correlation_id = correlation_id
            expected_message_id = message_id
            return_channel.on_return do |return_info, properties, _content|
              next unless returned_message_matches?(
                properties,
                correlation_id: expected_correlation_id,
                message_id: expected_message_id
              )

              record_return!(return_state, return_info)
            end
          end

          def returned_message_matches?(properties, correlation_id:, message_id:)
            return false if property_mismatch?(properties, :correlation_id, correlation_id)
            return false if property_mismatch?(properties, :message_id, message_id)

            true
          end

          def property_mismatch?(properties, key, expected)
            return false unless expected
            return false unless properties.respond_to?(key)

            value = properties.public_send(key)
            value && value != expected
          end

          def record_return!(return_state, return_info)
            return_state[:returned] = true
            return_state[:reply_code] = return_info.reply_code if return_info.respond_to?(:reply_code)
            return_state[:reply_text] = return_info.reply_text if return_info.respond_to?(:reply_text)
          end

          def prepare_publisher_confirms(exchange_dest, options)
            return unless options[:publisher_confirm] == true

            confirm_channel = publish_channel(exchange_dest)
            confirm_channel.confirm_select if confirm_channel.respond_to?(:confirm_select)
          end

          def publish_result(exchange_dest, options, return_state)
            status = confirm_publish(exchange_dest, options)
            status = :unroutable if return_state[:returned]
            {
              status: status,
              accepted: status == :accepted,
              exchange: exchange_name(exchange_dest),
              routing_key: options[:routing_key] || routing_key || '',
              message_id: message_id,
              return_reply_code: return_state[:reply_code],
              return_reply_text: return_state[:reply_text],
              correlation_id: correlation_id
            }.compact
          end

          def publish_failure_result(status, error, options)
            {
              status: status,
              accepted: false,
              error_class: error.class.name,
              error: error.message,
              routing_key: options[:routing_key] || routing_key || '',
              message_id: message_id,
              correlation_id: correlation_id
            }.compact
          end

          def confirm_publish(exchange_dest, options)
            return :accepted unless options[:publisher_confirm] == true

            confirm_channel = publish_channel(exchange_dest)
            return :accepted unless confirm_channel.respond_to?(:wait_for_confirms)

            timeout = options[:publish_confirm_timeout_ms]
            confirmed = if timeout
                          confirm_channel.wait_for_confirms(timeout.to_f / 1000.0)
                        else
                          confirm_channel.wait_for_confirms
                        end
            confirmed == false ? :nacked : :accepted
          rescue Timeout::Error => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.fleet.publish.confirm')
            :confirm_timeout
          end

          def publish_channel(exchange_dest)
            return exchange_dest.channel if exchange_dest.respond_to?(:channel)

            channel
          end

          def exchange_name(exchange_dest)
            return exchange_dest.name if exchange_dest.respond_to?(:name)

            exchange_dest.to_s
          end
        end
      end
    end
  end
end
