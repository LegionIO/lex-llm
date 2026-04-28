# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Routing
        # Builds stable fleet lane keys from provider-neutral model offerings.
        module LaneKey
          module_function

          def for(offering, prefix: 'llm.fleet', include_context: true, include_fingerprint: false)
            parts = [prefix, lane_kind(offering), model_slug(lane_model(offering))]
            if include_context && offering.inference? && offering.context_window
              parts << "ctx#{offering.context_window}"
            end
            parts.push('elig', eligibility_fingerprint(offering)) if include_fingerprint
            parts.join('.')
          end

          def lane_model(offering)
            return offering.canonical_model_alias if offering.respond_to?(:canonical_model_alias) &&
                                                     offering.canonical_model_alias.to_s != ''

            offering.model
          end

          def lane_kind(offering)
            offering.embedding? ? 'embed' : 'inference'
          end

          def model_slug(model)
            model.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
          end

          def eligibility_fingerprint(offering)
            canonical = {
              usage_type: offering.usage_type,
              capabilities: offering.capabilities.sort,
              context_window: offering.context_window,
              max_output_tokens: offering.max_output_tokens,
              policy_tags: offering.policy_tags.sort,
              metadata: fingerprint_metadata(offering.metadata)
            }
            Digest::SHA1.hexdigest(Legion::JSON.generate(canonical))[0, 10]
          end

          def fingerprint_metadata(metadata)
            metadata.fetch(:eligibility, {})
                    .to_h
                    .transform_keys(&:to_sym)
                    .reject { |key, _| sensitive_fingerprint_key?(key) }
                    .sort
                    .to_h
          end

          def sensitive_fingerprint_key?(key)
            %i[credential credentials endpoint endpoint_url identity path prompt reply_to secret secrets token
               url].include?(key)
          end
        end
      end
    end
  end
end
