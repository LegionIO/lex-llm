# frozen_string_literal: true

require 'legion/transport'

module Legion
  module Extensions
    module Llm
      module Transport
        module Exchanges
          # Shared topic exchange for live LLM fleet requests and replies.
          class Fleet < ::Legion::Transport::Exchange
            def exchange_name
              'llm.fleet'
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
