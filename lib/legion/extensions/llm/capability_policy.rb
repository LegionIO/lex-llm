# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Resolves capability truth from multiple sources with explicit precedence.
      # Returns both a flat capability list and per-capability source metadata.
      module CapabilityPolicy
        OPTIONAL_CAPABILITIES = %i[
          completion embedding streaming tools vision thinking structured_output
          moderation image audio_transcription audio_speech
        ].freeze

        BOOLEAN_ALIASES = OPTIONAL_CAPABILITIES.each_with_object({}) do |capability, result|
          result[:"enable_#{capability}"] = capability
          result[:"#{capability}_flag"] = capability
        end.merge(
          enable_embeddings: :embedding,
          embeddings_flag: :embedding,
          enable_functions: :tools,
          functions_flag: :tools,
          tool_flag: :tools,
          enable_function_calling: :tools,
          function_calling_flag: :tools,
          enable_reasoning: :thinking,
          reasoning_flag: :thinking,
          enable_images: :image,
          images_flag: :image,
          enable_image_generation: :image,
          image_generation_flag: :image,
          enable_audio_generation: :audio_speech,
          audio_generation_flag: :audio_speech
        ).freeze

        module_function

        def resolve(real:, provider_catalog:, probe:, provider_envelope:, provider_config:, instance_config:, model_config:) # rubocop:disable Metrics/ParameterLists
          sources = {}
          OPTIONAL_CAPABILITIES.each do |capability|
            sources[capability] = resolve_one(
              capability,
              real:, provider_catalog:, probe:, provider_envelope:,
              provider_config:, instance_config:, model_config:
            )
          end

          {
            capabilities: sources.filter_map { |capability, data| capability if data[:value] == true },
            sources: sources
          }
        end

        def resolve_one(capability, real:, provider_catalog:, probe:, provider_envelope:, provider_config:, instance_config:, model_config:) # rubocop:disable Metrics/ParameterLists
          model_overrides = normalized_overrides(model_config)
          return { value: model_overrides[capability], source: :model_override } if model_overrides.key?(capability)

          instance_overrides = normalized_overrides(instance_config)
          return { value: instance_overrides[capability], source: :instance_override } if instance_overrides.key?(capability)

          provider_overrides = normalized_overrides(provider_config)
          return { value: provider_overrides[capability], source: :provider_override } if provider_overrides.key?(capability)

          real_caps = normalized_booleans(real)
          return { value: real_caps[capability], source: :model_metadata } if real_caps.key?(capability)

          catalog_caps = normalized_booleans(provider_catalog)
          return { value: catalog_caps[capability], source: :provider_catalog } if catalog_caps.key?(capability)

          probe_caps = normalized_booleans(probe)
          return { value: probe_caps[capability], source: :probe } if probe_caps.key?(capability)

          provider_caps = normalized_booleans(provider_envelope)
          return { value: provider_caps[capability], source: :provider_envelope } if provider_caps.key?(capability)

          { value: false, source: :default_false }
        end

        def normalized_overrides(config)
          config = normalize_hash(config)
          caps_key = config.key?(:capabilities) ? :capabilities : 'capabilities'
          overrides = normalized_booleans(config[caps_key])
          BOOLEAN_ALIASES.each do |key, capability|
            value = config[key]
            value = config[key.to_s] if value.nil?
            next unless [true, false].include?(value)
            next if overrides.key?(capability)

            overrides[capability] = value
          end
          overrides
        end

        def normalized_booleans(value)
          normalize_hash(value).each_with_object({}) do |(key, raw), result|
            capability = canonical_capability(key)
            next if capability.nil?
            next unless OPTIONAL_CAPABILITIES.include?(capability)
            next unless [true, false].include?(raw)

            result[capability] = raw
          end
        end

        def canonical_capability(key)
          Legion::Extensions::Llm::Capabilities.normalize([key]).first
        end

        def normalize_hash(value)
          return {} unless value.respond_to?(:to_h)

          value.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        end
      end
    end
  end
end
