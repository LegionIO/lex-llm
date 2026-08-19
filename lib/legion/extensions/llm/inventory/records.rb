# frozen_string_literal: true

require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/immutable_value'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/callable_handle'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Documentation namespace anchor for the immutable inventory records
        # defined in this file: OfferingDraft, OfferingRecord, LaneRecord,
        # AvailabilityFact, ReadinessResult, InstanceRecord, PublicationStatus,
        # and MutationResult. The records themselves live directly under
        # Inventory so their canonical constant paths stay flat.
        module Records; end

        # Shared normalization/validation used by the immutable inventory and
        # routing records. Kept internal to the records so no record implements a
        # competing validator. See phase-1-lex-llm-additive.md sections 10 and 15.
        module RecordSupport
          module_function

          SECRET_KEY_TOKENS = %w[
            credential authorization token secret password apikey prompt endpointurl callable
          ].freeze

          PUBLICATION_SOURCES = %i[provider_catalog provider_static_catalog provider_control_plane].freeze

          WEIGHT_INPUT_KEYS = %i[instance model_or_offering provider tier].freeze
          IDENTITY_WEIGHT_INPUTS = {
            tier: 100, provider: 100, instance: 100, model_or_offering: 100
          }.freeze
          IDENTITY_BASE_WEIGHT = 100_000_000

          def validated_weight_pair(weight_inputs:, base_weight:)
            raise Errors::ValidationError, 'weight_inputs and base_weight must be supplied together' \
              if weight_inputs.nil? != base_weight.nil?

            return [IDENTITY_WEIGHT_INPUTS, IDENTITY_BASE_WEIGHT] if weight_inputs.nil?

            raise Errors::ValidationError, 'weight_inputs must be a Hash' \
              unless weight_inputs.is_a?(::Hash)
            raise Errors::ValidationError,
                  'weight_inputs must have keys tier/provider/instance/model_or_offering' \
              unless weight_inputs.keys.length == WEIGHT_INPUT_KEYS.length &&
                     WEIGHT_INPUT_KEYS.all? { |key| weight_inputs.key?(key) }
            raise Errors::ValidationError, 'weight_inputs values must be Integers >= 0' \
              unless weight_inputs.values.all? { |value| value.is_a?(::Integer) && value >= 0 }
            raise Errors::ValidationError, 'base_weight must be an Integer >= 0' \
              unless base_weight.is_a?(::Integer) && base_weight >= 0
            raise Errors::ValidationError, 'base_weight must equal the product of weight_inputs' \
              unless base_weight == weight_inputs.values.reduce(1, :*)

            [weight_inputs.dup.freeze, base_weight]
          end

          def check_unknown_kwargs!(kwargs:, members:)
            unknown = kwargs.keys - members
            raise Errors::ValidationError, "unknown keyword(s): #{unknown.join(', ')}" unless unknown.empty?
          end

          def valid_utf8?(string)
            [::Encoding::UTF_8, ::Encoding::US_ASCII].include?(string.encoding) && string.valid_encoding?
          end

          def sanitized_reason(value:, field:, max_bytes: 1024)
            raise Errors::ValidationError, "#{field} must be a String" unless value.is_a?(::String)

            # Coerce any source encoding to valid UTF-8 rather than raising: provider
            # error messages can be ASCII-8BIT/binary (raw response bodies, Ruby kernel
            # error messages). A reason is diagnostic text, not operator input to reject —
            # raising here would mask the real dispatch error as an unclassifiable 500 and
            # defeat fail-forward. Undecodable bytes are replaced.
            coerced = value.dup.force_encoding(::Encoding::UTF_8)
            coerced = coerced.scrub('?') unless coerced.valid_encoding?

            trimmed = coerced.strip
            raise Errors::ValidationError, "#{field} must not be empty" if trimmed.empty?
            raise Errors::ValidationError, "#{field} exceeds #{max_bytes} UTF-8 bytes" if trimmed.bytesize > max_bytes

            trimmed.b.dup.force_encoding(::Encoding::UTF_8).freeze
          end

          def optional_sanitized_reason(value:, field:, max_bytes: 1024)
            return nil if value.nil?

            sanitized_reason(value: value, field: field, max_bytes: max_bytes)
          end

          def nonnegative_integer(value:, field:)
            raise Errors::ValidationError, "#{field} must be a nonnegative Integer" unless nonnegative_integer?(value)

            value
          end

          def nonnegative_integer?(value)
            value.is_a?(::Integer) && !value.negative?
          end

          def boolean!(value:, field:)
            return value if [true, false].include?(value)

            raise Errors::ValidationError, "#{field} must be true or false"
          end

          def normalize_provider_family(value:, field: :provider_family)
            text = Identity.normalize_text(value: value, field: field).downcase
            raise Errors::ValidationError, "#{field} must be snake-case ASCII" unless text.match?(/\A[a-z][a-z0-9_]*\z/)

            text.to_sym
          end

          def optional_time(value:, field:)
            return nil if value.nil?
            raise Errors::ValidationError, "#{field} must be a Time" unless value.is_a?(::Time)

            value.dup.freeze
          end

          def frozen_metadata(value:, field: :metadata)
            reject_secret_keys!(value, field)
            ImmutableValue.copy_and_freeze(value: value, field: field)
          end

          def reject_secret_keys!(value, field)
            case value
            when ::Hash
              value.each do |key, nested|
                raise Errors::ValidationError, "#{field} contains a secret-like key" if secret_key?(key)

                reject_secret_keys!(nested, field)
              end
            when ::Array
              value.each { |element| reject_secret_keys!(element, field) }
            end
          end

          def secret_key?(key)
            normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, '')
            SECRET_KEY_TOKENS.any? { |token| normalized.include?(token) }
          end

          def validate_operation_evidence!(evidence)
            raise Errors::ValidationError, 'operation_evidence must be a Hash' unless evidence.is_a?(::Hash)

            normalized = {}
            evidence.each do |key, value|
              op = Taxonomies.normalize_operation(value: key, allow_aliases: false)
              raise Errors::ValidationError, "operation_evidence[#{op}] must be an OperationEvidence" unless value.is_a?(OperationEvidence)
              raise Errors::ValidationError, "operation_evidence[#{op}] operation must match key" unless value.operation == op
              raise Errors::ValidationError, "duplicate operation_evidence key #{op}" if normalized.key?(op)

              normalized[op] = value
            end
            raise Errors::ValidationError, 'operation_evidence keys must equal Taxonomies::OPERATIONS exactly' unless normalized.keys.sort == Taxonomies::OPERATIONS.sort

            normalized.freeze
          end

          def validate_capability_evidence!(evidence)
            raise Errors::ValidationError, 'capability_evidence must be a Hash' unless evidence.is_a?(::Hash)

            normalized = {}
            evidence.each do |key, value|
              cap = Legion::Extensions::Llm::Capabilities.canonical(key)
              raise Errors::ValidationError, "capability_evidence key #{cap} is not canonical" unless Legion::Extensions::Llm::Capabilities::CANONICAL.include?(cap)
              raise Errors::ValidationError, "capability_evidence[#{cap}] must be a CapabilityEvidence" unless value.is_a?(CapabilityEvidence)
              raise Errors::ValidationError, "capability_evidence[#{cap}] capability must match key" unless value.capability == cap
              raise Errors::ValidationError, "duplicate capability_evidence key #{cap}" if normalized.key?(cap)

              normalized[cap] = value
            end
            normalized.freeze
          end

          def validate_quota_domains!(quota_domains)
            raise Errors::ValidationError, 'quota_domains must be a Hash' unless quota_domains.is_a?(::Hash)

            normalized = {}
            quota_domains.each do |key, value|
              op = Taxonomies.normalize_operation(value: key, allow_aliases: false)
              normalized[op] = validate_quota_domain_value!(value: value, field: "quota_domains[#{op}]")
            end
            normalized.freeze
          end

          def validate_quota_domain_value!(value:, field:)
            raise Errors::ValidationError, "#{field} must be a nonempty opaque String" unless value.is_a?(::String) && valid_utf8?(value) && !value.strip.empty?

            value.dup.freeze
          end

          # Validates and returns the five scalar ValueEvidence fields shared by
          # OfferingDraft, OfferingRecord, and LaneRecord as a member Hash.
          def scalar_value_evidences(kwargs)
            {
              context_evidence: positive_int_value_evidence!(kwargs[:context_evidence], :context_evidence),
              max_output_evidence: positive_int_value_evidence!(kwargs[:max_output_evidence], :max_output_evidence),
              embedding_dimensions_evidence: embedding_dimensions_value_evidence!(
                kwargs[:embedding_dimensions_evidence], :embedding_dimensions_evidence
              ),
              model_revision_evidence: model_revision_value_evidence!(
                kwargs[:model_revision_evidence], :model_revision_evidence
              ),
              tokenizer_evidence: tokenizer_value_evidence!(kwargs[:tokenizer_evidence], :tokenizer_evidence)
            }
          end

          def value_evidence!(evidence, field)
            raise Errors::ValidationError, "#{field} must be a ValueEvidence" unless evidence.is_a?(ValueEvidence)

            evidence
          end

          def positive_int_value_evidence!(evidence, field)
            value_evidence!(evidence, field)
            raise Errors::ValidationError, "known #{field} must be a positive Integer" if evidence.known? && !(evidence.value.is_a?(::Integer) && evidence.value.positive?)

            evidence
          end

          def embedding_dimensions_value_evidence!(evidence, field)
            value_evidence!(evidence, field)
            return evidence unless evidence.known?

            dims = evidence.value
            valid = dims.is_a?(::Array) && !dims.empty? &&
                    dims.all? { |dim| dim.is_a?(::Integer) && dim.positive? } &&
                    dims == dims.uniq && dims == dims.sort
            raise Errors::ValidationError, "known #{field} must be a sorted, unique Array of positive Integers" unless valid

            evidence
          end

          def model_revision_value_evidence!(evidence, field)
            value_evidence!(evidence, field)
            return evidence unless evidence.known?

            revision = evidence.value
            valid = revision.is_a?(::String) && !revision.strip.empty? &&
                    valid_utf8?(revision) && revision.unicode_normalized?(:nfc)
            raise Errors::ValidationError, "known #{field} must be a nonempty NFC String" unless valid

            evidence
          end

          def tokenizer_value_evidence!(evidence, field)
            value_evidence!(evidence, field)
            return evidence unless evidence.known?

            descriptor = evidence.value
            unless descriptor.is_a?(::Hash) && descriptor.keys.sort == %i[estimator parameters version]
              raise Errors::ValidationError, "known #{field} must be exactly {estimator:, version:, parameters:}"
            end

            nonempty_nfc!(value: descriptor[:estimator], field: "#{field}.estimator")
            nonempty_nfc!(value: descriptor[:version], field: "#{field}.version")
            raise Errors::ValidationError, "#{field}.parameters must be a Hash" unless descriptor[:parameters].is_a?(::Hash)

            evidence
          end

          def nonempty_nfc!(value:, field:)
            valid = value.is_a?(::String) && !value.strip.empty? && valid_utf8?(value) && value.unicode_normalized?(:nfc)
            raise Errors::ValidationError, "#{field} must be a nonempty NFC String" unless valid

            value
          end

          def publication_source!(value:)
            raise Errors::ValidationError, "publication_source must be one of #{PUBLICATION_SOURCES.inspect}" unless PUBLICATION_SOURCES.include?(value)

            value
          end
        end

        # An off-registry provider draft of one offering. Carries the validated
        # write-time weight pair, but no provider family, instance ID, offering ID,
        # lane ID, callable, health, or default model. See section 10.1.
        OfferingDraft = ::Data.define(
          :provider_native_key, :model, :tier, :operation_evidence, :capability_evidence,
          :context_evidence, :max_output_evidence, :embedding_dimensions_evidence,
          :model_revision_evidence, :tokenizer_evidence, :quota_domains, :metadata, :publication_source,
          :weight_inputs, :base_weight
        ) do
          def initialize(**kwargs)
            kwargs = { capability_evidence: {}, quota_domains: {}, metadata: {} }.merge(kwargs)
            RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)
            weight_inputs, base_weight = RecordSupport.validated_weight_pair(
              weight_inputs: kwargs[:weight_inputs], base_weight: kwargs[:base_weight]
            )

            super(
              provider_native_key: Identity.normalize_text(value: kwargs[:provider_native_key], field: :provider_native_key),
              model: Identity.normalize_text(value: kwargs[:model], field: :model),
              tier: Identity.normalize_enum(value: kwargs[:tier], field: :tier, allowed: Taxonomies::TIERS),
              operation_evidence: RecordSupport.validate_operation_evidence!(kwargs[:operation_evidence]),
              capability_evidence: RecordSupport.validate_capability_evidence!(kwargs[:capability_evidence]),
              quota_domains: RecordSupport.validate_quota_domains!(kwargs[:quota_domains]),
              metadata: RecordSupport.frozen_metadata(value: kwargs[:metadata]),
              publication_source: RecordSupport.publication_source!(value: kwargs[:publication_source]),
              weight_inputs: weight_inputs,
              base_weight: base_weight,
              **RecordSupport.scalar_value_evidences(kwargs)
            )
          end
        end

        # A registry-owned offering with canonical identity, captured callable, and
        # the write-time weight pair copied unchanged from its draft. Only
        # Inventory::Publisher/Registry constructs it. See section 10.2.
        OfferingRecord = ::Data.define(
          :offering_id, :provider_native_key, :instance_key, :model, :tier, :operation_evidence,
          :capability_evidence, :context_evidence, :max_output_evidence, :embedding_dimensions_evidence,
          :model_revision_evidence, :tokenizer_evidence, :quota_domains, :metadata, :callable_handle,
          :publication_source, :weight_inputs, :base_weight
        ) do
          def initialize(**kwargs)
            RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)
            weight_inputs, base_weight = RecordSupport.validated_weight_pair(
              weight_inputs: kwargs[:weight_inputs], base_weight: kwargs[:base_weight]
            )
            instance_key = kwargs[:instance_key]
            callable_handle = kwargs[:callable_handle]
            raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            raise Errors::ValidationError, 'callable_handle must be a CallableHandle' unless callable_handle.is_a?(CallableHandle)

            native_key = Identity.normalize_text(value: kwargs[:provider_native_key], field: :provider_native_key)
            Identity.validate_offering_id!(value: kwargs[:offering_id], instance_key: instance_key, provider_native_key: native_key)

            super(
              offering_id: kwargs[:offering_id].dup.freeze,
              provider_native_key: native_key,
              instance_key: instance_key,
              model: Identity.normalize_text(value: kwargs[:model], field: :model),
              tier: Identity.normalize_enum(value: kwargs[:tier], field: :tier, allowed: Taxonomies::TIERS),
              operation_evidence: RecordSupport.validate_operation_evidence!(kwargs[:operation_evidence]),
              capability_evidence: RecordSupport.validate_capability_evidence!(kwargs[:capability_evidence]),
              quota_domains: RecordSupport.validate_quota_domains!(kwargs[:quota_domains]),
              metadata: RecordSupport.frozen_metadata(value: kwargs[:metadata]),
              callable_handle: callable_handle,
              publication_source: RecordSupport.publication_source!(value: kwargs[:publication_source]),
              weight_inputs: weight_inputs,
              base_weight: base_weight,
              **RecordSupport.scalar_value_evidences(kwargs)
            )
          end

          def supported_operations
            operation_evidence.select { |_op, evidence| evidence.supported? }.keys.sort
          end

          def unsupported_operations
            operation_evidence.select { |_op, evidence| evidence.unsupported? }.keys.sort
          end

          def unknown_operations
            operation_evidence.select { |_op, evidence| evidence.unknown? }.keys.sort
          end

          def operation_status(operation:)
            operation_evidence.fetch(Taxonomies.normalize_operation(value: operation, allow_aliases: false)).status
          end

          def capability_evidence_for(capability:)
            capability_evidence[Legion::Extensions::Llm::Capabilities.canonical(capability)]
          end

          def capability_status(capability:)
            evidence = capability_evidence_for(capability: capability)
            evidence.nil? ? :unknown : evidence.status
          end

          def quota_domain(operation:)
            quota_domains[Taxonomies.normalize_operation(value: operation, allow_aliases: false)]
          end
        end

        # An executable lane derived by the registry from one supported operation
        # of an OfferingRecord, with its write-time weight pair copied unchanged.
        # See section 10.3.
        LaneRecord = ::Data.define(
          :lane_id, :offering_id, :instance_key, :provider_family, :instance_id, :model, :tier, :operation,
          :capability_evidence, :context_evidence, :max_output_evidence, :embedding_dimensions_evidence,
          :model_revision_evidence, :tokenizer_evidence, :quota_domain, :metadata, :callable_handle,
          :publication_source, :weight_inputs, :base_weight
        ) do
          def initialize(**kwargs)
            RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)
            weight_inputs, base_weight = RecordSupport.validated_weight_pair(
              weight_inputs: kwargs[:weight_inputs], base_weight: kwargs[:base_weight]
            )
            instance_key = kwargs[:instance_key]
            callable_handle = kwargs[:callable_handle]
            raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            raise Errors::ValidationError, 'callable_handle must be a CallableHandle' unless callable_handle.is_a?(CallableHandle)

            family = RecordSupport.normalize_provider_family(value: kwargs[:provider_family])
            resolved_instance = Identity.normalize_text(value: kwargs[:instance_id], field: :instance_id)
            unless family == instance_key.provider_family && resolved_instance == instance_key.instance_id
              raise Errors::ValidationError, 'provider_family and instance_id must equal instance_key'
            end

            canonical_model = Identity.normalize_text(value: kwargs[:model], field: :model)
            canonical_operation = Taxonomies.normalize_operation(value: kwargs[:operation], allow_aliases: false)
            Identity.validate_lane_id!(
              value: kwargs[:lane_id], instance_key: instance_key, operation: canonical_operation,
              model: canonical_model, offering_id: kwargs[:offering_id]
            )

            super(
              lane_id: kwargs[:lane_id].dup.freeze,
              offering_id: kwargs[:offering_id].dup.freeze,
              instance_key: instance_key,
              provider_family: family,
              instance_id: resolved_instance,
              model: canonical_model,
              tier: Identity.normalize_enum(value: kwargs[:tier], field: :tier, allowed: Taxonomies::TIERS),
              operation: canonical_operation,
              capability_evidence: RecordSupport.validate_capability_evidence!(kwargs[:capability_evidence]),
              quota_domain: kwargs[:quota_domain].nil? ? nil : RecordSupport.validate_quota_domain_value!(value: kwargs[:quota_domain], field: :quota_domain),
              metadata: RecordSupport.frozen_metadata(value: kwargs[:metadata]),
              callable_handle: callable_handle,
              publication_source: RecordSupport.publication_source!(value: kwargs[:publication_source]),
              weight_inputs: weight_inputs,
              base_weight: base_weight,
              **RecordSupport.scalar_value_evidences(kwargs)
            )
          end
        end

        # The availability state of an exact instance. Carries no cooldown,
        # half-open, latency, success-count, or clock-expiry field. See 10.4.
        AvailabilityFact = ::Data.define(
          :state, :availability_revision, :source, :reason, :observed_at,
          :last_probe_started_at, :last_probe_completed_at, :last_probe_outcome, :unavailable_revision
        ) do
          def initialize(**kwargs)
            kwargs = {
              last_probe_started_at: nil, last_probe_completed_at: nil, last_probe_outcome: nil, unavailable_revision: nil
            }.merge(kwargs)
            RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)

            state = kwargs[:state]
            availability_revision = kwargs[:availability_revision]
            unavailable_revision = kwargs[:unavailable_revision]
            raise Errors::ValidationError, 'state must be a Taxonomies::AVAILABILITY_STATES value' unless Taxonomies::AVAILABILITY_STATES.include?(state)
            raise Errors::ValidationError, 'source must be a Taxonomies::AVAILABILITY_SOURCES value' unless Taxonomies::AVAILABILITY_SOURCES.include?(kwargs[:source])

            RecordSupport.nonnegative_integer(value: availability_revision, field: :availability_revision)
            validate_unavailable_revision!(state, availability_revision, unavailable_revision)
            resolved_outcome = validate_probe_telemetry!(
              kwargs[:last_probe_started_at], kwargs[:last_probe_completed_at], kwargs[:last_probe_outcome]
            )

            super(
              state: state,
              availability_revision: availability_revision,
              source: kwargs[:source],
              reason: RecordSupport.sanitized_reason(value: kwargs[:reason], field: :reason),
              observed_at: RecordSupport.optional_time(value: kwargs[:observed_at], field: :observed_at),
              last_probe_started_at: RecordSupport.optional_time(value: kwargs[:last_probe_started_at], field: :last_probe_started_at),
              last_probe_completed_at: RecordSupport.optional_time(value: kwargs[:last_probe_completed_at], field: :last_probe_completed_at),
              last_probe_outcome: resolved_outcome,
              unavailable_revision: unavailable_revision
            )
          end

          def validate_unavailable_revision!(state, availability_revision, unavailable_revision)
            if state == :unavailable
              raise Errors::ValidationError, 'unavailable state requires unavailable_revision == availability_revision' unless unavailable_revision == availability_revision
            elsif !unavailable_revision.nil?
              raise Errors::ValidationError, 'non-unavailable state requires unavailable_revision: nil'
            end
          end

          def validate_probe_telemetry!(started_at, completed_at, outcome)
            return nil if outcome.nil?
            raise Errors::ValidationError, 'last_probe_outcome must be nil, :success, or :failure' unless Taxonomies::PROBE_OUTCOMES.include?(outcome)
            raise Errors::ValidationError, 'a non-nil last_probe_outcome requires both probe timestamps' unless started_at.is_a?(::Time) && completed_at.is_a?(::Time)
            raise Errors::ValidationError, 'probe completion cannot precede start' if completed_at < started_at

            outcome
          end
        end

        # The result of a provider-specific safe readiness operation. Contains no
        # model output, prompt, tokens, callable, exception, or transition
        # instruction. See section 10.5.
        ReadinessResult = ::Data.define(:ready, :reason, :metadata) do
          def initialize(ready:, reason:, metadata: {})
            super(
              ready: RecordSupport.boolean!(value: ready, field: :ready),
              reason: RecordSupport.sanitized_reason(value: reason, field: :reason),
              metadata: RecordSupport.frozen_metadata(value: metadata)
            )
          end

          def ready?
            ready
          end
        end

        # An activated exact instance's complete published state. Its availability
        # is available or unavailable, never initializing. See section 10.6.
        InstanceRecord = ::Data.define(
          :instance_key, :callable_handle, :availability, :offerings_by_id,
          :publisher_id, :publisher_token_id, :published_sequence, :published_at
        ) do
          def initialize(**kwargs)
            RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)
            instance_key = kwargs[:instance_key]
            callable_handle = kwargs[:callable_handle]
            availability = kwargs[:availability]
            raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            raise Errors::ValidationError, 'callable_handle must be a CallableHandle' unless callable_handle.is_a?(CallableHandle)
            unless availability.is_a?(AvailabilityFact) && %i[available unavailable].include?(availability.state)
              raise Errors::ValidationError, 'availability must be an available/unavailable AvailabilityFact'
            end

            super(
              instance_key: instance_key,
              callable_handle: callable_handle,
              availability: availability,
              offerings_by_id: validate_offerings!(kwargs[:offerings_by_id], instance_key, callable_handle),
              publisher_id: nonempty_id!(kwargs[:publisher_id], :publisher_id),
              publisher_token_id: nonempty_id!(kwargs[:publisher_token_id], :publisher_token_id),
              published_sequence: RecordSupport.nonnegative_integer(value: kwargs[:published_sequence], field: :published_sequence),
              published_at: require_time!(kwargs[:published_at], :published_at)
            )
          end

          def validate_offerings!(offerings_by_id, instance_key, callable_handle)
            raise Errors::ValidationError, 'offerings_by_id must be a Hash' unless offerings_by_id.is_a?(::Hash)

            offerings_by_id.each do |offering_id, offering|
              raise Errors::ValidationError, "offering #{offering_id} must be an OfferingRecord" unless offering.is_a?(OfferingRecord)
              raise Errors::ValidationError, "offering #{offering_id} key mismatch" unless offering.offering_id == offering_id
              unless offering.instance_key == instance_key && offering.callable_handle.equal?(callable_handle)
                raise Errors::ValidationError, "offering #{offering_id} must share the instance callable/key"
              end
            end
            offerings_by_id.dup.freeze
          end

          def nonempty_id!(value, field)
            raise Errors::ValidationError, "#{field} must be a nonempty String" unless value.is_a?(::String) && !value.empty?

            value.dup.freeze
          end

          def require_time!(value, field)
            raise Errors::ValidationError, "#{field} must be a Time" unless value.is_a?(::Time)

            value.dup.freeze
          end
        end

        # Publication-scope status distinguishing an initializing claim from an
        # authoritative complete catalog. See section 10.7.
        PublicationStatus = ::Data.define(
          :instance_key, :state, :publisher_token_id, :published_sequence,
          :last_probe_started_at, :last_probe_completed_at, :last_probe_outcome, :last_error
        ) do
          def initialize(**kwargs)
            kwargs = {
              last_probe_started_at: nil, last_probe_completed_at: nil, last_probe_outcome: nil, last_error: nil
            }.merge(kwargs)
            RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)

            instance_key = kwargs[:instance_key]
            published_sequence = kwargs[:published_sequence]
            last_probe_outcome = kwargs[:last_probe_outcome]
            raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            raise Errors::ValidationError, 'state must be :initializing or :complete' unless Taxonomies::PUBLICATION_STATES.include?(kwargs[:state])
            raise Errors::ValidationError, 'published_sequence must be nil or a nonnegative Integer' unless published_sequence.nil? || RecordSupport.nonnegative_integer?(published_sequence)
            raise Errors::ValidationError, 'last_probe_outcome must be nil, :success, or :failure' unless last_probe_outcome.nil? || Taxonomies::PROBE_OUTCOMES.include?(last_probe_outcome)

            super(
              instance_key: instance_key,
              state: kwargs[:state],
              publisher_token_id: kwargs[:publisher_token_id].nil? ? nil : kwargs[:publisher_token_id].dup.freeze,
              published_sequence: published_sequence,
              last_probe_started_at: RecordSupport.optional_time(value: kwargs[:last_probe_started_at], field: :last_probe_started_at),
              last_probe_completed_at: RecordSupport.optional_time(value: kwargs[:last_probe_completed_at], field: :last_probe_completed_at),
              last_probe_outcome: last_probe_outcome,
              last_error: RecordSupport.optional_sanitized_reason(value: kwargs[:last_error], field: :last_error)
            )
          end
        end

        # The outcome of a registry mutation. Expected stale results use
        # applied: false; every other reason requires applied: true. See 10.8.
        MutationResult = ::Data.define(
          :applied, :reason, :generation, :instance_key, :publication_status, :instance_record
        ) do
          def initialize(**kwargs)
            kwargs = { publication_status: nil, instance_record: nil }.merge(kwargs)
            RecordSupport.check_unknown_kwargs!(kwargs: kwargs, members: self.class.members)

            applied = kwargs[:applied]
            reason = kwargs[:reason]
            instance_key = kwargs[:instance_key]
            publication_status = kwargs[:publication_status]
            instance_record = kwargs[:instance_record]
            RecordSupport.boolean!(value: applied, field: :applied)
            raise Errors::ValidationError, 'reason must be a Taxonomies::MUTATION_REASONS value' unless Taxonomies::MUTATION_REASONS.include?(reason)

            validate_applied_reason!(applied, reason)
            raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            raise Errors::ValidationError, 'publication_status must be a PublicationStatus or nil' unless publication_status.nil? || publication_status.is_a?(PublicationStatus)
            raise Errors::ValidationError, 'instance_record must be an InstanceRecord or nil' unless instance_record.nil? || instance_record.is_a?(InstanceRecord)

            super(
              applied: applied,
              reason: reason,
              generation: RecordSupport.nonnegative_integer(value: kwargs[:generation], field: :generation),
              instance_key: instance_key,
              publication_status: publication_status,
              instance_record: instance_record
            )
          end

          def applied?
            applied
          end

          def validate_applied_reason!(applied, reason)
            non_applied = %i[stale_publisher stale_probe already_removed]
            if applied
              raise Errors::ValidationError, "applied result cannot use reason #{reason}" if non_applied.include?(reason)
            elsif !non_applied.include?(reason)
              raise Errors::ValidationError, "non-applied result requires a stale/already-removed reason, got #{reason}"
            end
          end
        end
      end
    end
  end
end
