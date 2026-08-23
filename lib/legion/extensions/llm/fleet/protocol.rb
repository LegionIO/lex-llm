# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Fleet
        module Protocol
          # Fleet protocol v3 — the contract cut (06 P1). v2 envelopes are
          # rejected by design; there is no dual-protocol coexistence.
          VERSION = 3
          REQUEST_TYPE = 'llm.fleet.request'
          RESPONSE_TYPE = 'llm.fleet.response'
          ERROR_TYPE = 'llm.fleet.error'

          # P4: v1 legacy options rejected at both edges (one list).
          LEGACY_FIELDS = %i[schema_version request_type fleet_correlation_id].freeze

          # Every request is exact-execution (06 P2): the marker is REQUIRED and
          # must equal this value (it names the contract semantics, not the
          # protocol version). Marker absence is rejected.
          EXACT_EXECUTION_CONTRACT = 'exact_offering_v1'
          EXACT_REQUIRED_FIELDS = %i[
            execution_contract offering_id provider provider_instance model operation
          ].freeze
          EXACT_SIGNED_SCALAR_CLAIMS = %i[
            execution_contract offering_id
          ].freeze

          # The complete required envelope field set (06 E2) — the 16 protocol
          # fields plus the two exact fields. Both edges (FleetRequest and
          # ProviderResponder) consume this one list.
          REQUIRED_FIELDS = %i[
            request_id correlation_id idempotency_key operation provider provider_instance model params reply_to
            message_context caller trace_context signed_token timeout_seconds expires_at protocol_version
            execution_contract offering_id
          ].freeze
        end
      end
    end
  end
end
