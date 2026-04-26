# frozen_string_literal: true

module LexLLM
  module Providers
    class OpenAI
      # Moderation methods of the OpenAI API integration
      module Moderation
        module_function

        def moderation_url
          'moderations'
        end

        def render_moderation_payload(input, model:)
          {
            model: model,
            input: input
          }
        end

        def parse_moderation_response(response, model:)
          data = response.body
          raise Error.new(response, data.dig('error', 'message')) if data.dig('error', 'message')

          LexLLM::Moderation.new(
            id: data['id'],
            model: model,
            results: data['results'] || []
          )
        end
      end
    end
  end
end
