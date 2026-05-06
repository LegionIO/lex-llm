# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Documents the canonical public provider method signatures shared by provider gems.
      module ProviderContract
        REQUIRED_SIGNATURES = {
          chat: [%i[keyreq messages], %i[keyreq model]],
          stream_chat: [%i[keyreq messages], %i[keyreq model]],
          embed: [%i[keyreq text], %i[keyreq model]],
          image: [%i[keyreq prompt], %i[keyreq model]],
          list_models: [%i[key live], %i[keyrest filters]],
          discover_offerings: [%i[key live], %i[keyrest filters]],
          health: [%i[key live]],
          count_tokens: [%i[keyreq messages], %i[keyreq model], %i[key params]]
        }.freeze
      end
    end
  end
end
