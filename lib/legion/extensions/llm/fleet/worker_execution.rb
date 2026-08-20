# frozen_string_literal: true

require 'concurrent'

require_relative 'protocol'
require_relative 'settings'
require_relative 'token_validator'
require_relative 'fleet_envelope'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/registry'

module Legion
  module Extensions
    module Llm
      module Fleet
        # Applies responder-side policy and executes a fleet request against
        # the captured registry callable. Protocol v3: exact execution only —
        # one dispatch path (06 W1/W3), no provider-object topology.
        module WorkerExecution
          include Legion::Logging::Helper
          extend Legion::Logging::Helper

          class PolicyError < StandardError; end

          @idempotency_keys = Concurrent::Map.new
          @idempotency_mutex = Mutex.new

          module_function

          # The single dispatch entry (06 W1).
          def call(envelope:, registry:)
            raise PolicyError, 'WorkerExecution.call requires registry' if registry.nil?

            envelope = FleetEnvelope.wrap(envelope)
            claims = nil
            idempotency_key = nil
            claims = validate_identity!(envelope)
            validate_policy!(envelope)
            idempotency_key = validate_idempotency!(envelope)
            response = dispatch!(envelope:, registry:)
            mark_idempotency_success!(idempotency_key) if idempotency_key
            TokenValidator.mark_replay!(claims[:jti]) if claims.is_a?(Hash)
            response
          rescue TokenError => e
            handle_exception(e, level: :warn, handled: false, operation: 'llm.fleet.worker_execution.identity')
            release_idempotency!(idempotency_key) if idempotency_key
            release_replay!(claims)
            raise PolicyError, e.message
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: false, operation: 'llm.fleet.worker_execution.call')
            release_idempotency!(idempotency_key) if idempotency_key
            release_replay!(claims)
            raise
          end

          def validate_identity!(envelope)
            return true unless responder_setting(:require_auth, default: true)

            TokenValidator.validate!(token: envelope.signed_token, envelope: envelope.to_h)
          end

          # W6 fail-closed: require_policy with no policy engine configured
          # RAISES. The v2 warn-and-allow is deleted.
          def validate_policy!(_envelope)
            return true unless responder_setting(:require_policy, default: false)

            raise PolicyError, 'require_policy is enabled but no policy engine is configured'
          end

          def validate_idempotency!(envelope)
            return nil unless responder_setting(:require_idempotency, default: true)

            key = envelope.idempotency_key
            raise PolicyError, 'fleet idempotency_key is required' if key.to_s.empty?

            reserve_idempotency_key!(key.to_s)
            key.to_s
          end

          ERRORS = Legion::Extensions::Llm::Inventory::Errors
          IDENTITY = Legion::Extensions::Llm::Inventory::Identity

          # The one dispatcher (06 W3): the exact resolution chain (W2).
          def dispatch!(envelope:, registry:)
            snapshot = registry.snapshot
            instance_key = IDENTITY::InstanceKey.new(
              provider_family: envelope.provider, instance_id: envelope.provider_instance
            )
            record = available_record!(snapshot, instance_key)
            offering = record.offerings_by_id[envelope.offering_id]
            raise ERRORS::ExactOfferingMismatchError, 'offering_id not on the activated instance' if offering.nil?

            operation = exact_operation(envelope)
            model = require_matching_model!(offering, envelope)
            require_supported!(offering, operation)
            execute_via_lane(registry, snapshot,
                             { record: record, offering: offering, operation: operation, model: model, envelope: envelope })
          end

          def execute_via_lane(registry, snapshot, resolution)
            lane = matching_lane!(snapshot, resolution[:record], resolution[:offering], resolution[:operation], resolution[:model])
            lease = registry.acquire(callable_handle: lane.callable_handle)
            begin
              dispatch_operation(lease.callable, resolution[:operation], resolution[:model], exact_params(resolution[:envelope]))
            ensure
              lease.release
            end
          end

          def available_record!(snapshot, instance_key)
            record = snapshot.instance(instance_key: instance_key)
            raise ERRORS::ExactOfferingMismatchError, 'instance is absent, initializing, or unavailable' unless record && record.availability.state == :available

            record
          end

          # 06 §5: an unknown operation is a contract error at the worker.
          def exact_operation(envelope)
            Legion::Extensions::Llm::Taxonomies.normalize_operation(value: envelope.operation)
          rescue Legion::Extensions::Llm::Inventory::Errors::ValidationError
            raise ContractError, "unsupported exact operation: #{envelope.operation}"
          end

          def require_matching_model!(offering, envelope)
            model = IDENTITY.normalize_text(value: envelope.model, field: :model)
            raise ERRORS::ExactOfferingMismatchError, 'model does not match the offering' unless offering.model == model

            model
          end

          def require_supported!(offering, operation)
            return if offering.operation_status(operation: operation) == :supported

            raise ERRORS::ExactOfferingMismatchError, "operation #{operation} is not supported by the offering"
          end

          def matching_lane!(snapshot, record, offering, operation, model)
            lane_id = IDENTITY.lane_id(instance_key: record.instance_key, operation: operation, model: model, offering_id: offering.offering_id)
            lane = snapshot.lane(lane_id: lane_id)
            valid = lane && lane.offering_id == offering.offering_id && lane.instance_key == record.instance_key &&
                    lane.model == model && lane.operation == operation && lane.callable_handle.equal?(record.callable_handle)
            raise ERRORS::ExactOfferingMismatchError, 'no matching lane for the offering' unless valid

            lane
          end

          # W5 params strictness: no :model key (the Selection-derived model is
          # untouchable), no duplicate param spellings. Shape violations are
          # contract errors (06 §5), not offering mismatches.
          def exact_params(envelope)
            raw = envelope.params || {}
            params = {}
            raw.each do |key, value|
              sym = key.respond_to?(:to_sym) ? key.to_sym : key
              raise ContractError, "duplicate param spelling for #{sym}" if params.key?(sym)

              params[sym] = value
            end
            raise ContractError, 'params must not contain model' if params.key?(:model)

            params
          end

          # W4 — the named rehydration boundary: the ONLY place serialized wire
          # messages become Canonical::Message. Non-Hash/non-Message elements
          # are contract errors.
          def rehydrate_wire_messages(value)
            Array(value).map do |message|
              next message if message.is_a?(Canonical::Message)

              unless message.is_a?(Hash)
                raise ContractError,
                      "fleet wire message must be a serialized Canonical::Message, got #{message.class}"
              end

              Canonical::Message.from_hash(message)
            end
          end

          def dispatch_operation(callable, operation, model, params)
            case operation
            when :chat
              callable.chat(rehydrate_wire_messages(require_param!(params, :messages, operation)), model: model,
                                                                                                   **params.except(:messages))
            when :stream_chat
              callable.stream_chat(rehydrate_wire_messages(require_param!(params, :messages, operation)), model: model,
                                                                                                          **params.except(:messages))
            when :count_tokens
              callable.count_tokens(messages: rehydrate_wire_messages(require_param!(params, :messages, operation)), model: model,
                                    **params.except(:messages))
            when :embed
              callable.embed(text: require_param!(params, :text, operation), model: model, **params.except(:text))
            when :image
              dispatch_image(callable, model, params)
            when :transcribe
              dispatch_audio(callable, :transcribe, model, params)
            when :translate
              dispatch_audio(callable, :translate, model, params)
            when :speak
              dispatch_speak(callable, model, params)
            when :moderate
              callable.moderate(input: require_param!(params, :input, operation), model: model, **params.except(:input))
            else
              raise ContractError, "unsupported exact operation: #{operation}"
            end
          end

          def dispatch_image(callable, model, params)
            require_param!(params, :prompt, :image)
            require_param!(params, :size, :image)
            callable.image(prompt: params[:prompt], model: model, **params.except(:prompt))
          end

          def dispatch_audio(callable, operation, model, params)
            require_param!(params, :audio_file, operation)
            raise ContractError, "#{operation} requires the language key" unless params.key?(:language)

            callable.public_send(
              operation, params[:audio_file], model: model, language: params[:language],
                                              **params.except(:audio_file, :model, :language)
            )
          end

          def dispatch_speak(callable, model, params)
            require_param!(params, :text, :speak)
            callable.speak(params[:text], model: model, voice: params[:voice], **params.except(:text, :model, :voice))
          end

          def require_param!(params, key, operation)
            raise ContractError, "#{operation} requires the #{key} param" unless params.key?(key)

            params[key]
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

          MAX_IDEMPOTENCY_ENTRIES = 100_000

          def purge_idempotency_cache!
            @idempotency_mutex.synchronize do
              now = Time.now.to_i
              @idempotency_keys.each_pair do |key, entry|
                @idempotency_keys.delete(key) if entry[:expires_at] <= now
              end
              evict_oldest_idempotency_entries! if @idempotency_keys.size > MAX_IDEMPOTENCY_ENTRIES
            end
          end

          def evict_oldest_idempotency_entries!
            sorted = @idempotency_keys.each_pair.sort_by { |_key, entry| entry[:expires_at] }
            sorted.first(@idempotency_keys.size - MAX_IDEMPOTENCY_ENTRIES).each_key do |key|
              @idempotency_keys.delete(key)
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
        end
      end
    end
  end
end
