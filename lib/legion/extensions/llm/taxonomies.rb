# frozen_string_literal: true

require 'legion/extensions/llm/inventory/errors'

module Legion
  module Extensions
    module Llm
      # Frozen vocabularies shared across routing, inventory, and provider
      # contracts: legacy tier/type/circuit enums plus the SSOT v3 operation,
      # evidence, availability, outcome, and rejection enums.
      module Taxonomies
        TIERS           = %i[direct local fleet cloud frontier].freeze
        TYPES           = %i[inference embedding image audio].freeze

        # --- SSOT v3 runtime-contract enums (phase-1-lex-llm-additive.md section 6) ---
        OPERATIONS = %i[
          chat stream_chat embed image transcribe translate speak moderate count_tokens
        ].freeze

        CAPABILITY_EVIDENCE_STATES = %i[supported unsupported unknown].freeze
        OPERATION_EVIDENCE_STATES = %i[supported unsupported unknown].freeze
        VALUE_EVIDENCE_STATES = %i[known unknown].freeze
        AVAILABILITY_STATES = %i[initializing available unavailable].freeze
        AVAILABILITY_SOURCES = %i[startup_readiness readiness dispatch].freeze
        PROBE_OUTCOMES = %i[success failure].freeze
        PUBLICATION_STATES = %i[initializing complete].freeze
        CALLABLE_STATES = %i[active retiring disposed].freeze

        MUTATION_REASONS = %i[
          claimed activated snapshot_replaced readiness_observed instance_unavailable
          instance_recovered initial_readiness_failed removed stale_publisher stale_probe
          already_removed
        ].freeze

        PROVIDER_OUTCOMES = %i[
          success instance_unavailable overloaded model_not_ready rate_limited
          authentication authorization billing policy invalid_request model_missing
          context_rejected safety_refusal malformed_output tool_failure timeout
          connection_failure provider_error cancelled client_disconnect
        ].freeze

        REJECTION_KINDS = %i[
          invalid_routing_context invalid_request policy_denied failed_dependency
          too_early service_unavailable context_rejected attempts_exhausted stale_selection
        ].freeze

        EXCLUSION_TARGET_KINDS = %i[
          attempt_target lane offering instance provider model quota_domain
        ].freeze

        EXCLUSION_LIFETIMES = %i[request attempt_group].freeze

        BODY_MODEL_HINT_DISPOSITIONS = %i[
          absent auto superseded_by_explicit_model ignored_disabled
          ignored_not_whitelisted ignored_blacklisted honored
        ].freeze

        EVIDENCE_SOURCES = %i[
          provider_implementation model_metadata provider_catalog probe provider_envelope
          model_override instance_override provider_override default_false absent guessed
          failed_probe inconclusive_probe
        ].freeze

        UNKNOWN_ONLY_EVIDENCE_SOURCES = %i[
          model_override instance_override provider_override default_false absent guessed
          failed_probe inconclusive_probe
        ].freeze

        module_function

        # The one operation spelling (06 P5): canonical operations only, no
        # aliases. Unknown, empty, or invalid UTF-8 input always raises
        # Inventory::Errors::ValidationError.
        def normalize_operation(value:)
          raise Inventory::Errors::ValidationError, 'operation must be a String or Symbol' unless value.is_a?(::String) || value.is_a?(::Symbol)

          string = value.to_s
          raise Inventory::Errors::ValidationError, 'operation is not valid UTF-8' unless [::Encoding::UTF_8, ::Encoding::US_ASCII].include?(string.encoding) && string.valid_encoding?

          trimmed = string.strip
          raise Inventory::Errors::ValidationError, 'operation must not be empty' if trimmed.empty?

          candidate = trimmed.to_sym
          return candidate if OPERATIONS.include?(candidate)

          raise Inventory::Errors::ValidationError, "operation is not a canonical operation (#{candidate})"
        end
      end
    end
  end
end
