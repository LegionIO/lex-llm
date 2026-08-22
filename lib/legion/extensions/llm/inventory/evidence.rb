# frozen_string_literal: true

require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/immutable_value'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Immutable operation, capability, and value evidence with
        # authoritative/unknown semantics. See phase-1-lex-llm-additive.md
        # section 9.
        #
        # For every evidence record `observed_at` is nil or a duplicated frozen
        # Time used only for telemetry. It never participates in authority,
        # ordering, freshness, recovery, or selection.
        module Evidence
          module_function

          def normalize_observed_at(observed_at)
            return nil if observed_at.nil?
            raise Errors::ValidationError, 'observed_at must be a Time' unless observed_at.is_a?(::Time)

            observed_at.dup.freeze
          end

          def validate_evidence_status(status:, allowed:)
            raise Errors::ValidationError, "status must be one of #{allowed.inspect}" unless allowed.include?(status)

            status
          end

          def validate_evidence_source(source:)
            raise Errors::ValidationError, 'source is not one of Taxonomies::EVIDENCE_SOURCES' unless Taxonomies::EVIDENCE_SOURCES.include?(source)

            source
          end

          def enforce_unknown_only_source!(status:, source:)
            return unless Taxonomies::UNKNOWN_ONLY_EVIDENCE_SOURCES.include?(source)
            return if status == :unknown

            raise Errors::ValidationError, "source #{source} requires status :unknown"
          end
        end

        # Evidence that a provider instance supports (or is not known to support)
        # a canonical operation. `stream_chat` stays `stream_chat`; it never
        # canonicalizes into capability `streaming`.
        OperationEvidence = ::Data.define(:operation, :status, :source, :observed_at, :metadata) do
          def initialize(operation:, status:, source:, observed_at: nil, metadata: {})
            canonical_operation = Taxonomies.normalize_operation(value: operation)
            Evidence.validate_evidence_status(status: status, allowed: Taxonomies::OPERATION_EVIDENCE_STATES)
            Evidence.validate_evidence_source(source: source)
            Evidence.enforce_unknown_only_source!(status: status, source: source)

            super(
              operation: canonical_operation,
              status: status,
              source: source,
              observed_at: Evidence.normalize_observed_at(observed_at),
              metadata: ImmutableValue.copy_and_freeze(value: metadata, field: :metadata)
            )
          end

          def supported? = status == :supported
          def unsupported? = status == :unsupported
          def unknown? = status == :unknown
        end

        # Evidence that a provider instance supports (or is not known to support)
        # a canonical capability. Config permission, absent fields, default_false,
        # failed probes, and guesses must be constructed as :unknown, never
        # :unsupported.
        CapabilityEvidence = ::Data.define(:capability, :status, :source, :observed_at, :metadata) do
          def initialize(capability:, status:, source:, observed_at: nil, metadata: {})
            canonical_capability = Legion::Extensions::Llm::Capabilities.canonical(capability)
            raise Errors::ValidationError, "capability #{canonical_capability} is not canonical" unless Legion::Extensions::Llm::Capabilities::CANONICAL.include?(canonical_capability)

            Evidence.validate_evidence_status(status: status, allowed: Taxonomies::CAPABILITY_EVIDENCE_STATES)
            Evidence.validate_evidence_source(source: source)
            Evidence.enforce_unknown_only_source!(status: status, source: source)

            super(
              capability: canonical_capability,
              status: status,
              source: source,
              observed_at: Evidence.normalize_observed_at(observed_at),
              metadata: ImmutableValue.copy_and_freeze(value: metadata, field: :metadata)
            )
          end

          def supported? = status == :supported
          def unsupported? = status == :unsupported
          def unknown? = status == :unknown
        end

        # Evidence carrying a known scalar value (context limit, maximum output,
        # embedding dimensions, tokenizer/estimator, immutable model revision) or
        # an explicit :unknown. Each field uses a separate instance so one known
        # field cannot make another field authoritative.
        ValueEvidence = ::Data.define(:status, :value, :source, :observed_at, :metadata) do
          def initialize(status:, source:, value: nil, observed_at: nil, metadata: {})
            Evidence.validate_evidence_status(status: status, allowed: Taxonomies::VALUE_EVIDENCE_STATES)
            Evidence.validate_evidence_source(source: source)
            Evidence.enforce_unknown_only_source!(status: status, source: source)

            case status
            when :known
              raise Errors::ValidationError, 'known ValueEvidence requires a non-nil value' if value.nil?
            when :unknown
              raise Errors::ValidationError, 'unknown ValueEvidence requires value: nil' unless value.nil?
            end

            copied_value = value.nil? ? nil : ImmutableValue.copy_and_freeze(value: value, field: :value)

            super(
              status: status,
              value: copied_value,
              source: source,
              observed_at: Evidence.normalize_observed_at(observed_at),
              metadata: ImmutableValue.copy_and_freeze(value: metadata, field: :metadata)
            )
          end

          def known? = status == :known
          def unknown? = status == :unknown
        end
      end
    end
  end
end
