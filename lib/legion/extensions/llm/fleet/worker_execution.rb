# frozen_string_literal: true

require 'concurrent'

require_relative 'protocol'
require_relative 'settings'
require_relative 'token_validator'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/registry'

module Legion
  module Extensions
    module Llm
      module Fleet
        # Applies responder-side policy and dispatches a fleet request to a local lex-llm provider.
        module WorkerExecution
          include Legion::Logging::Helper
          extend Legion::Logging::Helper

          class PolicyError < StandardError; end

          @idempotency_keys = Concurrent::Map.new
          @idempotency_mutex = Mutex.new

          module_function

          def call(envelope:, registry: nil, provider: nil)
            validate_dispatch_target!(registry, provider)
            claims = nil
            idempotency_key = nil
            claims = validate_identity!(envelope)
            validate_policy!(envelope)
            idempotency_key = validate_idempotency!(envelope)
            response = dispatch!(envelope: envelope, registry: registry, provider: provider)
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

            TokenValidator.validate!(token: envelope_value(envelope, :signed_token), envelope: envelope)
          end

          def validate_policy!(_envelope) # rubocop:disable Naming/PredicateMethod
            return true unless responder_setting(:require_policy, default: false)

            log.warn('[fleet] require_policy is enabled but no policy engine is configured — allowing request')
            true
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
            params = unpack_legacy_options(params)
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

          ERRORS = Legion::Extensions::Llm::Inventory::Errors
          IDENTITY = Legion::Extensions::Llm::Inventory::Identity

          def validate_dispatch_target!(registry, provider)
            return unless registry.nil? == provider.nil?

            raise PolicyError, 'WorkerExecution.call requires exactly one of registry or provider'
          end

          def dispatch!(envelope:, registry:, provider:)
            return dispatch_local_provider!(envelope: envelope, provider: provider) if provider

            if envelope_value(envelope, :execution_contract) == Protocol::EXACT_EXECUTION_CONTRACT
              exact_dispatch!(envelope: envelope, registry: registry)
            else
              legacy_registry_dispatch!(envelope: envelope, registry: registry)
            end
          end

          # Exact path: resolve by signed offering_id; no model resolution, provider
          # scan, :default, or first value.
          def exact_dispatch!(envelope:, registry:)
            snapshot = registry.snapshot
            instance_key = exact_instance_key(envelope)
            record = available_record!(snapshot, instance_key)
            offering = record.offerings_by_id[envelope_value(envelope, :offering_id)]
            raise ERRORS::ExactOfferingMismatchError, 'offering_id not on the activated instance' if offering.nil?

            operation = exact_operation(envelope)
            model = require_matching_model!(offering, envelope)
            require_supported!(offering, operation)
            execute_via_lane(registry, snapshot,
                             { record: record, offering: offering, operation: operation, model: model, envelope: envelope })
          end

          # Registry-backed v2 compatibility path for a migrated provider: execute
          # only when (provider_family, instance, operation, model) resolves to
          # exactly one supported local offering.
          def legacy_registry_dispatch!(envelope:, registry:)
            snapshot = registry.snapshot
            instance_key = exact_instance_key(envelope)
            record = available_record!(snapshot, instance_key)
            operation = Legion::Extensions::Llm::Taxonomies.normalize_operation(value: envelope_value(envelope, :operation), allow_aliases: true)
            model = IDENTITY.normalize_text(value: envelope_value(envelope, :model), field: :model)
            matches = record.offerings_by_id.values.select { |o| o.model == model && o.operation_status(operation: operation) == :supported }
            raise ERRORS::ExactOfferingMismatchError, 'no matching local offering' if matches.empty?
            raise ERRORS::AmbiguousLegacyOfferingError, 'multiple matching local offerings' if matches.size > 1

            execute_via_lane(registry, snapshot,
                             { record: record, offering: matches.first, operation: operation, model: model, envelope: envelope })
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

          def exact_instance_key(envelope)
            IDENTITY::InstanceKey.new(
              provider_family: envelope_value(envelope, :provider), instance_id: envelope_value(envelope, :provider_instance)
            )
          end

          def available_record!(snapshot, instance_key)
            record = snapshot.instance(instance_key: instance_key)
            raise ERRORS::ExactOfferingMismatchError, 'instance is absent, initializing, or unavailable' unless record && record.availability.state == :available

            record
          end

          def exact_operation(envelope)
            Legion::Extensions::Llm::Taxonomies.normalize_operation(value: envelope_value(envelope, :operation), allow_aliases: false)
          end

          def require_matching_model!(offering, envelope)
            model = IDENTITY.normalize_text(value: envelope_value(envelope, :model), field: :model)
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

          def exact_params(envelope)
            raw = envelope_value(envelope, :params) || {}
            params = {}
            raw.each do |key, value|
              sym = key.respond_to?(:to_sym) ? key.to_sym : key
              raise ERRORS::ExactOfferingMismatchError, "duplicate param spelling for #{sym}" if params.key?(sym)

              params[sym] = value
            end
            raise ERRORS::ExactOfferingMismatchError, 'params must not contain model' if params.key?(:model)

            params
          end

          def dispatch_operation(callable, operation, model, params)
            case operation
            when :chat then callable.chat(messages: require_param!(params, :messages, operation), model: model, **except(params, :messages))
            when :stream_chat then callable.stream_chat(messages: require_param!(params, :messages, operation), model: model, **except(params, :messages))
            when :count_tokens then callable.count_tokens(messages: require_param!(params, :messages, operation), model: model, **except(params, :messages))
            when :embed then callable.embed(text: require_param!(params, :text, operation), model: model, **except(params, :text))
            when :image then dispatch_image(callable, model, params)
            when :transcribe then dispatch_audio(callable, :transcribe, model, params)
            when :translate then dispatch_audio(callable, :translate, model, params)
            when :speak then dispatch_speak(callable, model, params)
            when :moderate then callable.moderate(require_param!(params, :input, operation), model: model, **except(params, :input))
            else raise ERRORS::ExactOfferingMismatchError, "unsupported exact operation: #{operation}"
            end
          end

          def dispatch_image(callable, model, params)
            require_param!(params, :prompt, :image)
            require_param!(params, :size, :image)
            callable.image(prompt: params[:prompt], model: model, **except(params, :prompt))
          end

          def dispatch_audio(callable, operation, model, params)
            require_param!(params, :audio_file, operation)
            raise ERRORS::ExactOfferingMismatchError, "#{operation} requires the language key" unless params.key?(:language)

            callable.public_send(
              operation, params[:audio_file], model: model, language: params[:language],
                                              **except(params, :audio_file, :model, :language)
            )
          end

          def dispatch_speak(callable, model, params)
            require_param!(params, :text, :speak)
            callable.speak(params[:text], model: model, voice: params[:voice], **except(params, :text, :model, :voice))
          end

          def require_param!(params, key, operation)
            raise ERRORS::ExactOfferingMismatchError, "#{operation} requires the #{key} param" unless params.key?(key)

            params[key]
          end

          def unpack_legacy_options(params)
            options = params.delete(:options)
            return params unless options.is_a?(Hash)

            normalize_hash(options).each { |key, value| params[key] = value unless params.key?(key) }
            params
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

          def envelope_value(envelope, key)
            return nil unless envelope.respond_to?(:key?)
            return envelope[key] if envelope.key?(key)

            string_key = key.to_s
            return envelope[string_key] if envelope.key?(string_key)

            nil
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
