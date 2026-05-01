# frozen_string_literal: true

return unless defined?(Legion::Transport::Exchange)

module Legion
  module Extensions
    module Llm
      module Transport
        module Exchanges
          # Shared topic exchange for LLM provider availability events.
          # All lex-llm-* providers publish to the same `llm.registry` exchange.
          class LlmRegistry < ::Legion::Transport::Exchange
            def exchange_name
              'llm.registry'
            end

            def default_type
              'topic'
            end
          end
        end
      end
    end
  end
end
