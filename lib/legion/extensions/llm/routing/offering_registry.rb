# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Routing
        # In-memory index of provider-neutral model offerings.
        class OfferingRegistry
          include Enumerable

          def initialize(offerings = [])
            @offerings = []
            Array(offerings).each { |offering| register(offering) }
          end

          def register(offering)
            normalized = normalize_offering(offering)
            @offerings.reject! { |existing| existing.offering_id == normalized.offering_id }
            @offerings << normalized
            normalized
          end

          def each(&)
            @offerings.each(&)
          end

          def all
            @offerings.dup
          end
          alias list all

          def find(offering_id)
            @offerings.find { |offering| offering.offering_id == offering_id.to_s }
          end

          def find_by_model_alias(alias_name)
            @offerings.find { |offering| offering.model_alias?(alias_name) }
          end

          def filter(**criteria)
            @offerings.select do |offering|
              matches_symbol?(offering.provider_family, criteria[:provider_family]) &&
                matches_symbol?(offering.model_family, criteria[:model_family]) &&
                matches_symbol?(offering.provider_instance, criteria[:provider_instance]) &&
                matches_capability?(offering, criteria[:capability]) &&
                matches_model_alias?(offering, criteria[:model_alias]) &&
                matches_model?(offering, criteria[:model]) &&
                matches_usage_type?(offering, criteria[:usage_type])
            end
          end

          def by_provider_family(provider_family)
            filter(provider_family:)
          end

          def by_model_family(model_family)
            filter(model_family:)
          end

          def by_provider_instance(provider_instance)
            filter(provider_instance:)
          end

          def by_capability(capability)
            filter(capability:)
          end

          private

          def normalize_offering(offering)
            return offering if offering.is_a?(ModelOffering)

            ModelOffering.new(offering)
          end

          def matches_symbol?(actual, expected)
            expected.nil? || actual == expected.to_sym
          end

          def matches_capability?(offering, capability)
            capability.nil? || offering.supports?(capability)
          end

          def matches_model_alias?(offering, model_alias)
            model_alias.nil? || offering.model_alias?(model_alias)
          end

          def matches_model?(offering, model)
            model.nil? || offering.model == model.to_s
          end

          def matches_usage_type?(offering, usage_type)
            usage_type.nil? || offering.usage_type == usage_type.to_sym
          end
        end
      end
    end
  end
end
