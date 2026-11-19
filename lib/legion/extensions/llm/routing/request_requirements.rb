# frozen_string_literal: true

require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/routing/records'

module Legion
  module Extensions
    module Llm
      module Routing
        # Request-owned routing facts. Construction does not consult settings,
        # inventory, or provider state; consumers preserve this exact record.
        RequestRequirements = ::Data.define(
          :operation, :required_capabilities, :input_bound, :required_output_tokens, :context_budget,
          :requested_embedding_dimensions, :modality, :provider_pin, :instance_pin, :model_pin, :tier_pin,
          :body_model_hint_decision, :routing_seed, :maximum_attempts
        ) do
          # rubocop:disable-next Metrics/ParameterLists -- every immutable contract field is required
          def initialize(operation:, required_capabilities:, input_bound:, required_output_tokens:, context_budget:,
                         requested_embedding_dimensions:, modality:, provider_pin:, instance_pin:, model_pin:, tier_pin:,
                         body_model_hint_decision:, routing_seed:, maximum_attempts:)
            support = Legion::Extensions::Llm::Inventory::RecordSupport
            immutable = Legion::Extensions::Llm::Inventory::ImmutableValue
            errors = Legion::Extensions::Llm::Inventory::Errors
            raise errors::ValidationError, 'operation must be canonical' unless Legion::Extensions::Llm::Taxonomies::OPERATIONS.include?(operation)
            unless required_capabilities.is_a?(::Array) && required_capabilities.all? { |capability| Legion::Extensions::Llm::Capabilities::CANONICAL.include?(capability) }
              raise errors::ValidationError, 'required_capabilities must be an Array of canonical capabilities'
            end
            raise errors::ValidationError, 'tier_pin must be nil or a canonical tier' unless tier_pin.nil? || Legion::Extensions::Llm::Taxonomies::TIERS.include?(tier_pin)
            raise errors::ValidationError, 'provider_pin must be nil or a Symbol' unless provider_pin.nil? || provider_pin.is_a?(::Symbol)
            unless body_model_hint_decision.is_a?(Legion::Extensions::Llm::Routing::BodyModelHintDecision)
              raise errors::ValidationError, 'body_model_hint_decision must be a BodyModelHintDecision'
            end
            unless routing_seed.is_a?(::String) && support.valid_utf8?(routing_seed) && routing_seed.match?(/\A[0-9a-f]{32}\z/)
              raise errors::ValidationError, 'routing_seed must be 32 lowercase hexadecimal characters'
            end

            super(
              operation: operation, required_capabilities: required_capabilities.dup.freeze,
              input_bound: support.nonnegative_integer(value: input_bound, field: :input_bound),
              required_output_tokens: support.nonnegative_integer(value: required_output_tokens, field: :required_output_tokens),
              context_budget: support.nonnegative_integer(value: context_budget, field: :context_budget),
              requested_embedding_dimensions: requested_embedding_dimensions.nil? ? nil : positive_integer(value: requested_embedding_dimensions, field: :requested_embedding_dimensions),
              modality: immutable.copy_and_freeze(value: modality, field: :modality),
              provider_pin: provider_pin, instance_pin: optional_pin_text(value: instance_pin, field: :instance_pin),
              model_pin: optional_pin_text(value: model_pin, field: :model_pin), tier_pin: tier_pin,
              body_model_hint_decision: body_model_hint_decision, routing_seed: routing_seed.dup.freeze,
              maximum_attempts: positive_integer(value: maximum_attempts, field: :maximum_attempts)
            )
          end

          private

          def positive_integer(value:, field:)
            Legion::Extensions::Llm::Inventory::RecordSupport.nonnegative_integer(value: value, field: field)
            raise Legion::Extensions::Llm::Inventory::Errors::ValidationError, "#{field} must be positive" if value.zero?

            value
          end

          def optional_pin_text(value:, field:)
            return nil if value.nil?
            raise Legion::Extensions::Llm::Inventory::Errors::ValidationError, "#{field} must be nil or a nonempty String" unless value.is_a?(::String) && !value.strip.empty?

            Legion::Extensions::Llm::Inventory::ImmutableValue.copy_and_freeze(value: value, field: field)
          end
        end
      end
    end
  end
end
