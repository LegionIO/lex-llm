# frozen_string_literal: true

require 'concurrent'
require 'time'

require_relative 'settings'
require_relative 'token_error'

module Legion
  module Extensions
    module Llm
      module Fleet
        # Verifies responder-side fleet JWTs and prevents replay on provider nodes.
        module TokenValidator
          @seen_jtis = Concurrent::Map.new
          @replay_mutex = Mutex.new

          module_function

          def validate!(token:, envelope:, record_replay: true)
            raise TokenError, 'fleet token is required' if token.to_s.empty?

            claims = symbolize_keys(jwt_module.verify(
                                      token,
                                      verification_key: signing_key,
                                      issuer: issuer,
                                      algorithm: algorithm,
                                      verify_issuer: false
                                    ))
            validate_registered_claims!(claims)
            validate_request_expiry!(claims)
            validate_envelope_claims!(claims, symbolize_keys(envelope || {}))
            record_replay ? reserve_replay!(claims[:jti]) : ensure_not_replayed!(claims[:jti])
            claims
          rescue TokenError
            raise
          rescue StandardError => e
            raise TokenError, "fleet token verification failed: #{e.message}"
          end

          def reset_replay_cache!
            @seen_jtis = Concurrent::Map.new
            @replay_mutex = Mutex.new
          end

          def validate_registered_claims!(claims)
            now = Time.now.to_i
            raise TokenError, 'fleet token issuer mismatch' unless accepted_issuer?(claims[:iss])
            raise TokenError, 'fleet token audience mismatch' unless claims[:aud].to_s == audience
            if claims[:exp].nil? || claims[:exp].to_i + clock_skew_seconds <= now
              raise TokenError,
                    'fleet token expired'
            end
            if claims[:nbf].nil? || claims[:nbf].to_i - clock_skew_seconds > now
              raise TokenError,
                    'fleet token not yet valid'
            end
            raise TokenError, 'fleet token missing jti' if claims[:jti].to_s.empty?
          end

          def validate_request_expiry!(claims)
            expires_at = claims[:expires_at]
            raise TokenError, 'fleet request expires_at is required' if expires_at.to_s.empty?

            expires = Time.iso8601(expires_at.to_s)
            raise TokenError, 'fleet request expired' if expires + clock_skew_seconds <= Time.now.utc
          rescue ArgumentError
            raise TokenError, 'fleet request expires_at is invalid'
          end

          def validate_envelope_claims!(claims, envelope)
            %i[
              request_id correlation_id idempotency_key operation provider provider_instance
              model reply_to message_context params caller trace_context timeout_seconds expires_at
            ].each do |key|
              expected = canonical_value(envelope[key])
              actual = canonical_value(claims[key])
              raise TokenError, "fleet token #{key} claim mismatch" unless actual == expected
            end
          end

          def reserve_replay!(jti)
            @replay_mutex.synchronize do
              now = Time.now.to_i
              purge_replay_cache_locked!(now)
              existing = @seen_jtis[jti.to_s]
              raise TokenError, 'fleet token replay detected' if active_replay?(existing, now)

              @seen_jtis[jti.to_s] = replay_entry(:inflight, now)
            end
          end

          def mark_replay!(jti)
            @replay_mutex.synchronize do
              @seen_jtis[jti.to_s] = replay_entry(:complete)
            end
          end

          def release_replay!(jti)
            @replay_mutex.synchronize do
              entry = @seen_jtis[jti.to_s]
              @seen_jtis.delete(jti.to_s) if entry.nil? || entry[:state] == :inflight
            end
          end

          def ensure_not_replayed!(jti)
            @replay_mutex.synchronize do
              now = Time.now.to_i
              purge_replay_cache_locked!(now)
              raise TokenError, 'fleet token replay detected' if active_replay?(@seen_jtis[jti.to_s], now)
            end
          end

          def purge_replay_cache!
            @replay_mutex.synchronize { purge_replay_cache_locked!(Time.now.to_i) }
          end

          def purge_replay_cache_locked!(now)
            @seen_jtis.each_pair { |jti, entry| @seen_jtis.delete(jti) unless active_replay?(entry, now) }
          end

          def active_replay?(entry, now)
            entry && entry[:expires_at] > now
          end

          def replay_entry(state, now = Time.now.to_i)
            { state: state, expires_at: now + replay_ttl_seconds }
          end

          def replay_ttl_seconds
            ttl = Settings.value(:fleet, :auth, :replay_ttl_seconds, default: 600).to_i
            ttl.positive? ? ttl : 600
          end

          def accepted_issuer?(value)
            accepted_issuers.map(&:to_s).include?(value.to_s)
          end

          def accepted_issuers
            issuers = Settings.value(:fleet, :auth, :accepted_issuers, default: [issuer])
            issuers = [issuer] if Array(issuers).empty?
            Array(issuers)
          end

          def clock_skew_seconds
            Settings.value(:fleet, :auth, :max_clock_skew_seconds, default: 30).to_i
          end

          def issuer
            Settings.value(:fleet, :auth, :issuer, default: 'legion-llm')
          end

          def audience
            Settings.value(:fleet, :auth, :audience, default: 'lex-llm-fleet-worker')
          end

          def algorithm
            Settings.value(:fleet, :auth, :algorithm, default: 'HS256')
          end

          def signing_key
            if defined?(::Legion::Crypt) && ::Legion::Crypt.respond_to?(:cluster_secret)
              return ::Legion::Crypt.cluster_secret
            end

            raise TokenError, 'no signing key available - Legion::Crypt not initialized'
          rescue TokenError
            raise
          rescue StandardError => e
            raise TokenError, "no signing key available: #{e.message}"
          end

          def jwt_module
            return ::Legion::Crypt::JWT if defined?(::Legion::Crypt::JWT) && ::Legion::Crypt::JWT.respond_to?(:verify)

            raise TokenError, 'Legion::Crypt::JWT.verify unavailable'
          end

          def symbolize_keys(hash)
            return {} unless hash.respond_to?(:each)

            hash.each_with_object({}) do |(key, value), result|
              result[key.respond_to?(:to_sym) ? key.to_sym : key] = value
            end
          end

          def canonical_value(value)
            case value
            when Hash
              value.each_with_object({}) do |(key, child), result|
                result[key.to_s] = canonical_value(child)
              end.sort.to_h
            when Array
              value.map { |child| canonical_value(child) }
            when Symbol
              value.to_s
            else
              value
            end
          end
        end
      end
    end
  end
end
