# frozen_string_literal: true

# Direct dependency; the explicit receiver keeps Ruby 4's redundant-require cop from deleting it.
Kernel.require 'set'
require 'legion/extensions/llm/inventory/weight_schema'
require 'legion/extensions/llm/settings_cascade'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/taxonomies'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Tracks configured weight keys that currently have no published lane.
        class DormantWeightTracker
          def initialize
            @dormant = Set.new
          end

          def observe(configured_keys:, published_keys:)
            current = Set.new(configured_keys).difference(published_keys)
            newly_dormant = current.difference(@dormant).sort_by(&:inspect)
            @dormant.replace(current)
            newly_dormant
          end

          def clear!
            @dormant.clear
          end
        end

        # Shared atomic write-time weight publication for existing writer cadences.
        module WeightReconciler
          module_function

          def rebuild_offerings(settings:, instance_key:, offerings:)
            offerings.map do |draft|
              inputs = WeightSchema.weight_inputs(
                settings: settings,
                instance_key: instance_key,
                model: draft.model,
                tier: draft.tier,
                operation_evidence: draft.operation_evidence
              )
              draft.with(weight_inputs: inputs, base_weight: WeightSchema.base_weight(inputs))
            end.freeze
          end

          # Periodic discovery calls this AFTER its existing network/discovery work. Read
          # current Settings and perform weight rebuilding, comparison, sequence
          # allocation, publish, and cache update under the same writer mutex. No Settings
          # callback or separate reweight path exists.
          def commit_if_changed!(settings:, instance_id:, state:, discovered_offerings:, **publication)
            unknown = publication.keys - %i[mutex equivalent replace stable_signature]
            raise ArgumentError, "unknown publication keyword(s): #{unknown.join(', ')}" unless unknown.empty?

            mutex = publication.fetch(:mutex)
            equivalent = publication.fetch(:equivalent)
            replace = publication.fetch(:replace)
            stable_signature = publication[:stable_signature]
            mutex.synchronize do
              offerings = rebuild_offerings(
                settings: settings, instance_key: state.fetch(:instance_key),
                offerings: discovered_offerings
              )
              return false if equivalent.call(state.fetch(:offerings), offerings)

              if state.fetch(:published)
                commit_locked!(
                  instance_id: instance_id, state: state, offerings: offerings,
                  replace: replace, stable_signature: stable_signature
                )
              else
                cache_locked!(
                  state: state, offerings: offerings, stable_signature: stable_signature
                )
              end
              true
            end
          end

          # Track a claimed but not-yet-activated instance before its readiness I/O. An
          # ordinary writer pass may refresh its cached weights, but must never send a
          # replacement for a publication that is still :initializing.
          def track_initializing!(states:, state_key:, state:, mutex:)
            mutex.synchronize do
              state[:published] = false
              states[state_key] = state
            end
            state
          end

          # Initial and recovery activation both use this helper after readiness succeeds.
          # Rebuild from current settings and publish under the writer's publication
          # mutex, then mark the state published only after the publisher call succeeds.
          def activate_tracked!(settings:, instance_id:, state_key:, state:, **activation)
            unknown = activation.keys - %i[states mutex probe_token activate activation_sequence stable_signature]
            raise ArgumentError, "unknown activation keyword(s): #{unknown.join(', ')}" unless unknown.empty?

            states = activation.fetch(:states)
            mutex = activation.fetch(:mutex)
            probe_token = activation.fetch(:probe_token)
            activate = activation.fetch(:activate)
            activation_sequence = activation.fetch(:activation_sequence)
            stable_signature = activation[:stable_signature]
            mutex.synchronize do
              return false unless states[state_key].equal?(state)

              offerings = rebuild_offerings(
                settings: settings, instance_key: state.fetch(:instance_key),
                offerings: state.fetch(:offerings)
              )
              sequence = activation_sequence.call(state)
              activate.call(
                instance_id: instance_id, state: state, offerings: offerings,
                sequence: sequence, probe_token: probe_token
              )
              state[:sequence] = sequence
              cache_locked!(
                state: state, offerings: offerings, stable_signature: stable_signature
              )
              state[:published] = true
              true
            end
          end

          # Ordinary ticks call this after reconcile. Dormant observation has the same
          # cadence as the existing writer; there is no reload callback path.
          def observe_dormant!(settings:, provider_family:, states:, mutex:, **observation)
            unknown = observation.keys - %i[tracker dormant_logger]
            raise ArgumentError, "unknown observation keyword(s): #{unknown.join(', ')}" unless unknown.empty?

            tracker = observation.fetch(:tracker)
            dormant_logger = observation.fetch(:dormant_logger)
            mutex.synchronize do
              observe_dormant_locked!(
                settings: settings, provider_family: provider_family, states: states,
                tracker: tracker, dormant_logger: dormant_logger
              )
            end
          end

          def commit_locked!(instance_id:, state:, offerings:, replace:, stable_signature:)
            sequence = state.fetch(:sequence) + 1
            replace.call(instance_id: instance_id, state: state, offerings: offerings, sequence: sequence)
            state[:sequence] = sequence
            cache_locked!(
              state: state, offerings: offerings, stable_signature: stable_signature
            )
          end
          private_class_method :commit_locked!

          def cache_locked!(state:, offerings:, stable_signature:)
            state[:offerings] = offerings
            state[:signature] = stable_signature.call(offerings) if stable_signature
          end
          private_class_method :cache_locked!

          def observe_dormant_locked!(settings:, provider_family:, states:, tracker:,
                                      dormant_logger:)
            configured = configured_weight_keys(settings: settings, provider_family: provider_family)
            published = published_weight_keys(provider_family: provider_family, states: states)
            tracker.observe(configured_keys: configured, published_keys: published).each do |key|
              dormant_logger.call(key)
            end
          end
          private_class_method :observe_dormant_locked!

          def configured_weight_keys(settings:, provider_family:)
            llm = config_hash(settings.dig(:extensions, :llm))
            provider = config_hash(SettingsCascade.lookup(llm, provider_family))
            keys = Set.new
            keys << canonical_key(provider_family, :provider) if weight_present?(provider)

            config_hash(SettingsCascade.lookup(provider, :models)).each do |model, config|
              keys << canonical_key(provider_family, :model, model.to_s) if weight_present?(config_hash(config))
            end
            config_hash(SettingsCascade.lookup(provider, :instances)).each do |instance, config|
              instance_config = config_hash(config)
              keys << canonical_key(provider_family, :instance, instance.to_s) if weight_present?(instance_config)
              config_hash(SettingsCascade.lookup(instance_config, :models)).each do |model, model_config|
                next unless weight_present?(config_hash(model_config))

                keys << canonical_key(
                  provider_family, :instance, instance.to_s, :model, model.to_s
                )
              end
            end
            config_hash(SettingsCascade.lookup(provider, :offerings)).each do |offering_id, config|
              keys << canonical_key(provider_family, :offering, offering_id.to_s) \
                if weight_present?(config_hash(config))
            end
            keys
          end

          def published_weight_keys(provider_family:, states:)
            keys = Set.new
            states.each_value do |state|
              next unless state.fetch(:published)

              offerings = Array(state[:offerings])
              next if offerings.empty?

              instance_key = state.fetch(:instance_key)
              keys << canonical_key(provider_family, :provider)
              keys << canonical_key(provider_family, :instance, instance_key.instance_id.to_s)
              offerings.each do |draft|
                keys << canonical_key(provider_family, :model, draft.model.to_s)
                keys << canonical_key(
                  provider_family, :instance, instance_key.instance_id.to_s,
                  :model, draft.model.to_s
                )
                draft.operation_evidence.each_value do |evidence|
                  next unless evidence.supported?

                  lane_id = Identity.compose_lane_id(
                    tier: draft.tier, provider_family: instance_key.provider_family,
                    instance_id: instance_key.instance_id,
                    type: Taxonomies.lane_type_for(operation: evidence.operation), model: draft.model
                  )
                  keys << canonical_key(provider_family, :offering, lane_id)
                end
              end
            end
            keys
          end

          def canonical_key(provider_family, *parts)
            [provider_family.to_sym, *parts].freeze
          end
          private_class_method :canonical_key

          def config_hash(value)
            return {} if value.nil?
            return value if value.is_a?(::Hash)

            raise ArgumentError, "weight configuration scope must be a Hash, got #{value.inspect}"
          end
          private_class_method :config_hash

          def weight_present?(scope)
            !SettingsCascade.lookup(scope, :weight).nil?
          end
          private_class_method :weight_present?
        end
      end
    end
  end
end
