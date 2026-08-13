# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Fleet
        module Protocol
          VERSION = 2
          REQUEST_TYPE = 'llm.fleet.request'
          RESPONSE_TYPE = 'llm.fleet.response'
          ERROR_TYPE = 'llm.fleet.error'

          # Additive exact-execution marker (phase-1-lex-llm-additive.md section 16.1).
          # An exact request is protocol v2 plus execution_contract == this marker
          # and a signed offering_id. Marker absence means legacy v2; an unknown
          # nonempty marker is rejected.
          EXACT_EXECUTION_CONTRACT = 'exact_offering_v1'
          EXACT_REQUIRED_FIELDS = %i[
            execution_contract offering_id provider provider_instance model operation
          ].freeze
          EXACT_SIGNED_SCALAR_CLAIMS = %i[
            execution_contract offering_id
          ].freeze
        end
      end
    end
  end
end
