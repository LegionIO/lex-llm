# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Manages model aliases for provider-specific versions
      class Aliases
        class << self
          def resolve(model_id, provider = nil)
            return model_id unless aliases[model_id]

            if provider
              aliases[model_id][provider.to_s] || model_id
            else
              aliases[model_id].values.first || model_id
            end
          end

          def normalize_model_alias(model_id)
            model_id.to_s.strip
          end

          def canonical_model_alias(model_id, provider = nil)
            normalized = normalize_model_alias(model_id)
            provider_name = provider&.to_s

            aliases.each do |alias_name, provider_map|
              next unless alias_matches?(provider_map, normalized, provider_name)

              return alias_name
            end

            normalized
          end

          def aliases
            @aliases ||= load_aliases
          end

          def aliases_file
            File.expand_path('aliases.json', __dir__)
          end

          def load_aliases
            if File.exist?(aliases_file)
              Legion::JSON.parse(File.read(aliases_file), symbolize_names: false)
            else
              {}
            end
          end

          def reload!
            @aliases = load_aliases
          end

          private

          def alias_matches?(provider_map, model_id, provider)
            return provider_map[provider] == model_id if provider

            provider_map.value?(model_id)
          end
        end
      end
    end
  end
end
