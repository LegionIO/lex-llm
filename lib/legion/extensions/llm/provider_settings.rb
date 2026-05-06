# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Builds shared provider defaults for lex-llm-* extension gems.
      module ProviderSettings
        module_function

        def build(family:, instance: {}, enabled: true, discovery: {}, instances: {}, fleet: nil, gateways: nil, # rubocop:disable Metrics/ParameterLists
                  **legacy_settings)
          validate_provider_defaults!(fleet:, gateways:, legacy_settings:)

          deep_merge(
            Legion::Extensions::Llm.default_settings,
            {
              enabled: enabled,
              provider_family: family,
              discovery: deep_merge({ enabled: true, interval_seconds: 300 }, discovery || {}),
              instances: deep_merge(
                {
                  default: deep_merge(
                    { enabled: true, credentials: nil, fleet: { enabled: false, consumer_priority: 0, prefetch: 1 } },
                    instance || {}
                  )
                },
                instances || {}
              )
            }
          )
        end

        def validate_provider_defaults!(fleet:, gateways:, legacy_settings:)
          if fleet
            raise ArgumentError,
                  'Provider fleet defaults must be nested under an instance, for example instances.default.fleet'
          end

          raise ArgumentError, 'Provider gateways settings are no longer supported; use instances instead' if gateways

          return if legacy_settings.empty?

          invalid_keys = legacy_settings.keys.map(&:to_sym)
          raise ArgumentError, "Unsupported top-level provider settings: #{invalid_keys.join(', ')}"
        end

        def deep_dup(value)
          case value
          when Hash
            value.to_h { |key, inner_value| [key, deep_dup(inner_value)] }
          when Array
            value.map { |inner_value| deep_dup(inner_value) }
          else
            value
          end
        end

        def deep_merge(left, right)
          deep_dup(left || {}).merge(deep_dup(right || {})) do |_key, left_value, right_value|
            left_value.is_a?(Hash) && right_value.is_a?(Hash) ? deep_merge(left_value, right_value) : right_value
          end
        end
      end
    end
  end
end
