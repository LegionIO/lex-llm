# frozen_string_literal: true

require 'legion/extensions/llm/settings_cascade'
require 'legion/extensions/llm/inventory/identity'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Write-time lane-weight computation (RANKING v2 law): the stateless router
        # reads the stored scalar; it is computed ONLY here, at write events, from a
        # live settings read. Each multiplicative axis reads ITS OWN scope — never a
        # fall-through cascade (a fall-through would double-count the other axes).
        module WeightSchema
          module_function

          IDENTITY = 100

          # Exact 4-key hash. offering_id derives from instance_key + the REAL
          # provider native key (NOT the model — azure's native key is
          # deployment_name, which can differ from model_id).
          def weight_inputs(settings:, instance_key:, provider_native_key:, model:, tier:)
            llm_conf = scope_hash(settings.dig(:extensions, :llm), path: 'extensions.llm')
            provider_conf = scope_hash(
              SettingsCascade.lookup(llm_conf, instance_key.provider_family),
              path: "extensions.llm.#{instance_key.provider_family}"
            )
            instances = scope_hash(
              SettingsCascade.lookup(provider_conf, :instances), path: 'provider.instances'
            )
            instance_cfg = scope_hash(
              SettingsCascade.lookup(instances, instance_key.instance_id),
              path: "provider.instances.#{instance_key.instance_id}"
            )
            tier_weights = scope_hash(
              settings.dig(:llm, :routing, :tier_weights), path: 'llm.routing.tier_weights'
            )
            offering_id = Identity.offering_id(instance_key: instance_key, provider_native_key: provider_native_key)
            offerings = scope_hash(SettingsCascade.lookup(provider_conf, :offerings), path: 'provider.offerings')
            offering_conf = scope_hash(
              SettingsCascade.lookup(offerings, offering_id), path: "provider.offerings.#{offering_id}"
            )
            provider_models = scope_hash(
              SettingsCascade.lookup(provider_conf, :models), path: 'provider.models'
            )
            instance_models = scope_hash(
              SettingsCascade.lookup(instance_cfg, :models), path: 'instance.models'
            )
            scope_hash(
              SettingsCascade.lookup(provider_models, model), path: "provider.models.#{model}"
            )
            scope_hash(
              SettingsCascade.lookup(instance_models, model), path: "instance.models.#{model}"
            )
            model_scopes = scope_hash(
              SettingsCascade.merge_model_scopes(
                provider_conf: provider_conf, instance_cfg: instance_cfg, model: model
              ),
              path: "merged model scope #{model}"
            )

            offering_w = SettingsCascade.lookup(offering_conf, :weight)
            model_w = SettingsCascade.lookup(model_scopes, :weight)
            {
              tier: component(SettingsCascade.lookup(tier_weights, tier), IDENTITY),
              provider: component(SettingsCascade.lookup(provider_conf, :weight), IDENTITY),
              instance: component(SettingsCascade.lookup(instance_cfg, :weight), IDENTITY),
              # Explicit nil? precedence (NEVER `||`): offering overrides the model
              # component only; nil offering → model; both nil → identity. A
              # non-nil non-Integer (false, strings, negatives) RAISES in `component`.
              model_or_offering: component(offering_w.nil? ? model_w : offering_w, IDENTITY)
            }
          end

          # nil → default; an explicit 0 passes through (0 = operator disable —
          # 0 is TRUTHY in Ruby and must not be defaulted); any other non-Integer
          # RAISES instead of silently applying a different weight.
          def component(value, default)
            return default if value.nil?

            raise ArgumentError, "weight component must be an Integer >= 0, got #{value.inspect}" \
              unless value.is_a?(::Integer) && value >= 0

            value
          end

          # Missing scope is the identity default. A present malformed scope is
          # never treated as missing (`false || {}` would silently erase operator
          # input and recreate a flat identity result).
          def scope_hash(value, path:)
            return {} if value.nil?
            return value if value.is_a?(::Hash)

            raise ArgumentError, "#{path} must be a Hash, got #{value.inspect}"
          end

          # Pinned return contract: TWO methods. The writer calls both:
          #   wi = WeightSchema.weight_inputs(...)
          #   base = WeightSchema.base_weight(wi)
          def base_weight(weight_inputs)
            weight_inputs.values.reduce(1, :*)
          end
        end
      end
    end
  end
end
