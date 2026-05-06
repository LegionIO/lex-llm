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
        end
      end
    end
  end
end
