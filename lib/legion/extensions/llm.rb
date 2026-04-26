# frozen_string_literal: true

require 'lex_llm'
require 'legion/extensions/llm/transport/fleet_lane'

module Legion
  module Extensions
    # Legion-native namespace for the shared LLM provider framework.
    module Llm
      VERSION = LexLLM::VERSION unless const_defined?(:VERSION, false)

      # Provider-neutral value objects exposed under the Legion extension namespace.
      module Types
        ModelOffering = LexLLM::Routing::ModelOffering unless const_defined?(:ModelOffering, false)
      end

      # Shared routing helpers exposed under the Legion extension namespace.
      module Routing
        LaneKey = LexLLM::Routing::LaneKey unless const_defined?(:LaneKey, false)
      end

      def self.default_settings
        {
          fleet: {
            enabled: false,
            scheduler: :basic_get,
            consumer_priority: 0,
            queue_expires_ms: 60_000,
            message_ttl_ms: 120_000,
            queue_max_length: 100,
            delivery_limit: 3,
            consumer_ack_timeout_ms: 300_000,
            endpoint: {
              enabled: false,
              empty_lane_backoff_ms: 250,
              idle_backoff_ms: 1_000,
              max_consecutive_pulls_per_lane: 0,
              accept_when: []
            }
          }
        }
      end
    end
  end
end
