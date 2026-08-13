# frozen_string_literal: true

require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/immutable_value'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/callable_handle'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/taxonomies'

module Legion
  module Extensions
    module Llm
      module Routing
        # Documentation namespace anchor for the request-local routing records
        # defined in this file: AttemptTargetKey, QuotaDomainKey, Exclusion,
        # Selection, Rejection, and BodyModelHintDecision. The records live
        # directly under Routing so their canonical constant paths stay flat.
        module Records; end

        # The canonical request-local exclusion target: provider family, exact
        # instance ID, and model. No operation, offering/lane ID, generation,
        # tier, weight, or affinity. See section 15.1.
        AttemptTargetKey = ::Data.define(:provider_family, :instance_id, :model) do
          def initialize(provider_family:, instance_id:, model:)
            key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
              provider_family: provider_family, instance_id: instance_id
            )
            model_text = Legion::Extensions::Llm::Inventory::Identity.normalize_text(value: model, field: :model)
            super(provider_family: key.provider_family, instance_id: key.instance_id, model: model_text)
          end
        end

        # A non-secret, provider-scoped quota domain. Equality never crosses
        # provider family. See section 15.2.
        QuotaDomainKey = ::Data.define(:provider_family, :opaque_id) do
          def initialize(provider_family:, opaque_id:)
            super(
              provider_family: Legion::Extensions::Llm::Inventory::RecordSupport.normalize_provider_family(
                value: provider_family
              ),
              opaque_id: Legion::Extensions::Llm::Inventory::Identity.normalize_text(value: opaque_id, field: :opaque_id)
            )
          end
        end

        # A request-local or attempt-group exclusion of a typed target. See 15.3.
        Exclusion = ::Data.define(:target_kind, :target, :reason, :evidence, :lifetime) do
          def initialize(target_kind:, target:, reason:, evidence:, lifetime:)
            raise Legion::Extensions::Llm::Inventory::Errors::ValidationError, 'invalid target_kind' unless Legion::Extensions::Llm::Taxonomies::EXCLUSION_TARGET_KINDS.include?(target_kind)
            raise Legion::Extensions::Llm::Inventory::Errors::ValidationError, 'invalid lifetime' unless Legion::Extensions::Llm::Taxonomies::EXCLUSION_LIFETIMES.include?(lifetime)

            super(
              target_kind: target_kind,
              target: normalize_target(target_kind, target),
              reason: Legion::Extensions::Llm::Inventory::RecordSupport.sanitized_reason(value: reason, field: :reason),
              evidence: Legion::Extensions::Llm::Inventory::ImmutableValue.copy_and_freeze(value: evidence, field: :evidence),
              lifetime: lifetime
            )
          end

          def normalize_target(target_kind, target)
            errors = Legion::Extensions::Llm::Inventory::Errors
            case target_kind
            when :attempt_target
              raise errors::ValidationError, 'attempt_target target must be an AttemptTargetKey' unless target.is_a?(AttemptTargetKey)

              target
            when :instance
              raise errors::ValidationError, 'instance target must be an InstanceKey' unless target.is_a?(Legion::Extensions::Llm::Inventory::Identity::InstanceKey)

              target
            when :quota_domain
              raise errors::ValidationError, 'quota_domain target must be a QuotaDomainKey' unless target.is_a?(QuotaDomainKey)

              target
            when :provider
              Legion::Extensions::Llm::Inventory::RecordSupport.normalize_provider_family(value: target, field: :target)
            else # :lane, :offering, :model
              Legion::Extensions::Llm::Inventory::Identity.normalize_text(value: target, field: target_kind)
            end
          end
        end

        # An immutable selected target produced by legion-llm's selector and
        # consumed by dispatch. lex-llm validates cross-field identity only; it
        # does not compute routing or choose a lane. See section 15.4.
        Selection = ::Data.define(
          :inventory_generation, :lane_id, :instance_key, :offering_id, :provider_family, :instance_id,
          :model, :operation, :callable_handle, :publisher_token_id, :capability_evidence, :context_evidence,
          :weight_inputs, :base_weight, :preference_ppm, :effective_weight, :rendezvous_score
        ) do
          def initialize(**kwargs)
            Legion::Extensions::Llm::Inventory::RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)
            super(**identity_attributes(kwargs).merge(scoring_attributes(kwargs)))
          end

          def identity_attributes(kwargs)
            errors = Legion::Extensions::Llm::Inventory::Errors
            identity = Legion::Extensions::Llm::Inventory::Identity
            instance_key = kwargs[:instance_key]
            callable_handle = kwargs[:callable_handle]
            raise errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(identity::InstanceKey)
            raise errors::ValidationError, 'callable_handle must be a CallableHandle' unless callable_handle.is_a?(Legion::Extensions::Llm::Inventory::CallableHandle)

            canonical_model = identity.normalize_text(value: kwargs[:model], field: :model)
            canonical_operation = Legion::Extensions::Llm::Taxonomies.normalize_operation(value: kwargs[:operation], allow_aliases: false)
            family = Legion::Extensions::Llm::Inventory::RecordSupport.normalize_provider_family(value: kwargs[:provider_family])
            resolved_instance = identity.normalize_text(value: kwargs[:instance_id], field: :instance_id)
            unless family == instance_key.provider_family && resolved_instance == instance_key.instance_id
              raise errors::ValidationError, 'provider_family and instance_id must equal instance_key'
            end

            offering_id = kwargs[:offering_id]
            validate_offering_id_shape!(offering_id)
            identity.validate_lane_id!(
              value: kwargs[:lane_id], instance_key: instance_key, operation: canonical_operation,
              model: canonical_model, offering_id: offering_id
            )
            validate_publisher_token_id!(kwargs[:publisher_token_id])

            {
              lane_id: kwargs[:lane_id].dup.freeze, instance_key: instance_key, offering_id: offering_id.dup.freeze,
              provider_family: family, instance_id: resolved_instance, model: canonical_model,
              operation: canonical_operation, callable_handle: callable_handle,
              publisher_token_id: kwargs[:publisher_token_id].dup.freeze
            }
          end

          def scoring_attributes(kwargs)
            support = Legion::Extensions::Llm::Inventory::RecordSupport
            base_weight = kwargs[:base_weight]
            frozen_weight_inputs = validate_weight_inputs!(kwargs[:weight_inputs], base_weight)
            validate_weights!(base_weight, kwargs[:preference_ppm], kwargs[:effective_weight], kwargs[:rendezvous_score])

            {
              inventory_generation: support.nonnegative_integer(value: kwargs[:inventory_generation], field: :inventory_generation),
              capability_evidence: support.validate_capability_evidence!(kwargs[:capability_evidence]),
              context_evidence: support.positive_int_value_evidence!(kwargs[:context_evidence], :context_evidence),
              weight_inputs: frozen_weight_inputs, base_weight: base_weight, preference_ppm: kwargs[:preference_ppm],
              effective_weight: kwargs[:effective_weight], rendezvous_score: kwargs[:rendezvous_score]
            }
          end

          def attempt_target_key
            AttemptTargetKey.new(provider_family: provider_family, instance_id: instance_id, model: model)
          end

          def validate_offering_id_shape!(offering_id)
            return if offering_id.is_a?(::String) && offering_id.match?(/\Aoff:v1:[0-9a-f]{64}\z/)

            raise Legion::Extensions::Llm::Inventory::Errors::ValidationError, 'offering_id must have the off:v1: shape'
          end

          def validate_publisher_token_id!(publisher_token_id)
            return if publisher_token_id.is_a?(::String) && publisher_token_id.start_with?('ptok:v1:') &&
                      publisher_token_id.length > 'ptok:v1:'.length

            raise Legion::Extensions::Llm::Inventory::Errors::ValidationError, 'publisher_token_id must be a ptok:v1: String'
          end

          def validate_weight_inputs!(weight_inputs, base_weight)
            errors = Legion::Extensions::Llm::Inventory::Errors
            unless weight_inputs.is_a?(::Hash) && weight_inputs.keys.sort == %i[instance model_or_offering provider tier]
              raise errors::ValidationError, 'weight_inputs must have keys tier/provider/instance/model_or_offering'
            end
            raise errors::ValidationError, 'weight_inputs values must be positive Integers' unless weight_inputs.values.all? { |value| value.is_a?(::Integer) && value.positive? }

            product = weight_inputs.values.reduce(1, :*)
            raise errors::ValidationError, 'base_weight must equal the product of weight_inputs' unless base_weight == product

            weight_inputs.dup.freeze
          end

          def validate_weights!(base_weight, preference_ppm, effective_weight, rendezvous_score)
            errors = Legion::Extensions::Llm::Inventory::Errors
            raise errors::ValidationError, 'preference_ppm must be an Integer in 500_000..1_500_000' unless preference_ppm.is_a?(::Integer) && (500_000..1_500_000).cover?(preference_ppm)
            raise errors::ValidationError, 'effective_weight must equal base_weight * preference_ppm' unless effective_weight == base_weight * preference_ppm
            return if rendezvous_score.is_a?(::Integer) && (0...(2**256)).cover?(rendezvous_score)

            raise errors::ValidationError, 'rendezvous_score must be an Integer in 0...(2**256)'
          end
        end

        # A routing rejection diagnosis. lex-llm validates/holds the value;
        # legion-llm constructs routing diagnoses and HTTP mappings. See 15.5.
        Rejection = ::Data.define(
          :kind, :reason, :inventory_generation, :candidate_counts, :explicit_pins, :http_status, :code
        ) do
          def initialize(**kwargs)
            kwargs = { explicit_pins: {}, http_status: nil, code: nil }.merge(kwargs)
            Legion::Extensions::Llm::Inventory::RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)
            support = Legion::Extensions::Llm::Inventory::RecordSupport
            errors = Legion::Extensions::Llm::Inventory::Errors
            raise errors::ValidationError, 'kind must be a Taxonomies::REJECTION_KINDS value' unless Legion::Extensions::Llm::Taxonomies::REJECTION_KINDS.include?(kwargs[:kind])

            super(
              kind: kwargs[:kind],
              reason: support.sanitized_reason(value: kwargs[:reason], field: :reason),
              inventory_generation: support.nonnegative_integer(value: kwargs[:inventory_generation], field: :inventory_generation),
              candidate_counts: validate_candidate_counts!(kwargs[:candidate_counts]),
              explicit_pins: validate_explicit_pins!(kwargs[:explicit_pins]),
              http_status: validate_http_status!(kwargs[:http_status]),
              code: validate_code!(kwargs[:code])
            )
          end

          def validate_candidate_counts!(candidate_counts)
            errors = Legion::Extensions::Llm::Inventory::Errors
            raise errors::ValidationError, 'candidate_counts must be a Hash' unless candidate_counts.is_a?(::Hash)

            candidate_counts.each do |key, value|
              raise errors::ValidationError, 'candidate_counts keys must be Symbols' unless key.is_a?(::Symbol)
              raise errors::ValidationError, 'candidate_counts values must be nonnegative Integers' unless value.is_a?(::Integer) && !value.negative?
            end
            candidate_counts.dup.freeze
          end

          def validate_explicit_pins!(explicit_pins)
            errors = Legion::Extensions::Llm::Inventory::Errors
            raise errors::ValidationError, 'explicit_pins must be a Hash' unless explicit_pins.is_a?(::Hash)
            unless explicit_pins.keys.all? { |key| %i[provider instance model tier].include?(key) }
              raise errors::ValidationError, 'explicit_pins may contain only provider/instance/model/tier'
            end

            Legion::Extensions::Llm::Inventory::ImmutableValue.copy_and_freeze(value: explicit_pins, field: :explicit_pins)
          end

          def validate_http_status!(http_status)
            return nil if http_status.nil?
            return http_status if http_status.is_a?(::Integer) && (100..599).cover?(http_status)

            raise Legion::Extensions::Llm::Inventory::Errors::ValidationError, 'http_status must be nil or 100..599'
          end

          def validate_code!(code)
            return nil if code.nil?
            return code if code.is_a?(::Symbol)
            return code.dup.freeze if code.is_a?(::String) && !code.strip.empty?

            raise Legion::Extensions::Llm::Inventory::Errors::ValidationError, 'code must be nil or a nonempty Symbol/String'
          end
        end

        # The disposition of a body-supplied model hint. The record performs no
        # matching and cannot dispatch. See section 15.6.
        BodyModelHintDecision = ::Data.define(
          :requested_model, :disposition, :model_constraint, :matched_whitelist, :matched_blacklist, :settings_generation
        ) do
          def initialize(**kwargs)
            kwargs = { model_constraint: nil, matched_whitelist: nil, matched_blacklist: nil }.merge(kwargs)
            Legion::Extensions::Llm::Inventory::RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)
            support = Legion::Extensions::Llm::Inventory::RecordSupport
            errors = Legion::Extensions::Llm::Inventory::Errors
            disposition = kwargs[:disposition]
            raise errors::ValidationError, 'invalid disposition' unless Legion::Extensions::Llm::Taxonomies::BODY_MODEL_HINT_DISPOSITIONS.include?(disposition)

            resolved_requested = optional_text(kwargs[:requested_model], :requested_model)
            resolved_constraint = optional_text(kwargs[:model_constraint], :model_constraint)
            validate_disposition_rules!(disposition, resolved_requested, resolved_constraint)

            super(
              requested_model: resolved_requested,
              disposition: disposition,
              model_constraint: resolved_constraint,
              matched_whitelist: optional_text(kwargs[:matched_whitelist], :matched_whitelist),
              matched_blacklist: optional_text(kwargs[:matched_blacklist], :matched_blacklist),
              settings_generation: support.nonnegative_integer(value: kwargs[:settings_generation], field: :settings_generation)
            )
          end

          def optional_text(value, field)
            return nil if value.nil?

            Legion::Extensions::Llm::Inventory::Identity.normalize_text(value: value, field: field)
          end

          def validate_disposition_rules!(disposition, requested_model, model_constraint)
            errors = Legion::Extensions::Llm::Inventory::Errors
            raise errors::ValidationError, 'only honored may carry a model_constraint' if disposition != :honored && !model_constraint.nil?
            return unless disposition == :absent && !requested_model.nil?

            raise errors::ValidationError, 'absent must carry a nil requested_model'
          end
        end
      end
    end
  end
end
