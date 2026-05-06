# frozen_string_literal: true

require 'concurrent'

require_relative 'settings'
require_relative 'token_validator'

module Legion
  module Extensions
    module Llm
      module Fleet
        # Applies responder-side policy and dispatches a fleet request to a local lex-llm provider.
        module WorkerExecution
          class PolicyError < StandardError; end

          @idempotency_keys = Concurrent::Map.new
          @idempotency_mutex = Mutex.new

          module_function

          def call(envelope:, provider:)
            claims = nil
            idempotency_key = nil
            claims = validate_identity!(envelope)
            validate_policy!(envelope)
            idempotency_key = validate_idempotency!(envelope)
            response = dispatch_local_provider!(envelope: envelope, provider: provider)
            mark_idempotency_success!(idempotency_key) if idempotency_key
            TokenValidator.mark_replay!(claims[:jti]) if claims.is_a?(Hash)
            response
          rescue TokenError => e
            release_idempotency!(idempotency_key) if idempotency_key
            release_replay!(claims)
            raise PolicyError, e.message
          rescue StandardError
            release_idempotency!(idempotency_key) if idempotency_key
            release_replay!(claims)
            raise
          end

          def validate_identity!(envelope)
            return true unless responder_setting(:require_auth, default: true)

            TokenValidator.validate!(token: envelope_value(envelope, :signed_token), envelope: envelope)
          end

          def validate_policy!(_envelope)
            return true unless responder_setting(:require_policy, default: false)

            raise PolicyError, 'fleet responder policy enforcement unavailable'
          end

          def validate_idempotency!(envelope)
            return nil unless responder_setting(:require_idempotency, default: true)

            key = envelope_value(envelope, :idempotency_key)
            raise PolicyError, 'fleet idempotency_key is required' if key.to_s.empty?

            reserve_idempotency_key!(key.to_s)
            key.to_s
          end

          def dispatch_local_provider!(envelope:, provider:)
            provider = provider.call(envelope) if provider.respond_to?(:call) && !provider.respond_to?(:chat)
            operation = envelope_value(envelope, :operation).to_sym
            params = normalize_hash(envelope_value(envelope, :params) || {})
            model = envelope_value(envelope, :model)

            case operation
            when :chat
              provider.chat(messages: params.fetch(:messages, []), model: model, **except(params, :messages))
            when :stream
              provider.stream_chat(messages: params.fetch(:messages, []), model: model, **except(params, :messages))
            when :embed
              provider.embed(text: params[:text], model: model, **except(params, :text))
            when :count_tokens
              provider.count_tokens(messages: params.fetch(:messages, []), model: model, **except(params, :messages))
            else
              raise PolicyError, "unsupported fleet operation: #{operation}"
            end
          end

          def reset_idempotency_cache!
            @idempotency_keys = Concurrent::Map.new
            @idempotency_mutex = Mutex.new
          end

          def mark_idempotency_success!(key)
            @idempotency_mutex.synchronize do
              @idempotency_keys[key.to_s] = { state: :complete, expires_at: Time.now.to_i + idempotency_ttl_seconds }
            end
          end

          def release_idempotency!(key)
            @idempotency_mutex.synchronize { @idempotency_keys.delete(key.to_s) }
          end

          def release_replay!(claims)
            return unless claims.is_a?(Hash) && claims[:jti]

            TokenValidator.release_replay!(claims[:jti])
          end

          def purge_idempotency_cache!
            @idempotency_mutex.synchronize do
              now = Time.now.to_i
              @idempotency_keys.each_pair do |key, entry|
                @idempotency_keys.delete(key) if entry[:expires_at] <= now
              end
            end
          end

          def reserve_idempotency_key!(key)
            @idempotency_mutex.synchronize do
              now = Time.now.to_i
              existing = @idempotency_keys[key]
              raise PolicyError, 'duplicate fleet idempotency key' if existing && existing[:expires_at] > now

              @idempotency_keys[key] = { state: :inflight, expires_at: now + idempotency_ttl_seconds }
            end
          end

          def idempotency_ttl_seconds
            ttl = responder_setting(:idempotency_ttl_seconds, default: 600).to_i
            ttl.positive? ? ttl : 600
          end

          def responder_setting(key, default:)
            value = Settings.value(:fleet, :responder, key, default: nil)
            return auth_required? if key == :require_auth && value.nil?
            return default if value.nil?

            value
          end

          def auth_required?
            Settings.value(:fleet, :auth, :require_signed_token, default: true) != false
          end

          def envelope_value(envelope, key)
            return nil unless envelope.respond_to?(:key?)

            envelope[key] || envelope[key.to_s]
          end

          def normalize_hash(hash)
            return {} unless hash.respond_to?(:each)

            hash.each_with_object({}) do |(key, value), result|
              result[key.respond_to?(:to_sym) ? key.to_sym : key] = value
            end
          end

          def except(hash, *keys)
            exclusions = keys.map(&:to_sym)
            hash.each_with_object({}) do |(key, value), result|
              normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
              result[normalized_key] = value unless exclusions.include?(normalized_key)
            end
          end
        end
      end
    end
  end
end
