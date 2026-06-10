# frozen_string_literal: true

# rubocop:disable Metrics/PerceivedComplexity -- from_hash normalization is intentional
module Legion
  module Extensions
    module Llm
      module Canonical
        # rubocop:disable Lint/ConstantDefinitionInBlock -- required for Data.define block scope
        # Canonical sampling and limit parameters for a request.
        # Per G18: all standard/useful params are first-class, mapped per provider by translators.
        Params = ::Data.define(
          :max_tokens, :max_thinking_tokens, :temperature, :top_p, :top_k,
          :stop_sequences, :seed, :frequency_penalty, :presence_penalty,
          :response_format
        ) do
          PARAMS_KNOWN_KEYS = %i[max_tokens max_thinking_tokens temperature top_p top_k
                                 stop_sequences seed frequency_penalty presence_penalty
                                 response_format].freeze

          # Build from a Hash (raw client request or deserialized wire payload).
          # Accepts both canonical key names and common provider spellings.
          def self.from_hash(source)
            return nil if source.nil? || source.empty?

            h = source.transform_keys(&:to_sym)

            # Normalize common provider key variations
            h[:max_tokens] ||= h.delete(:max_output_tokens) || h.delete(:num_predict)
            h[:max_thinking_tokens] ||= h.delete(:budget_tokens) || h.delete(:thinking_budget)
            h[:stop_sequences] ||= h.delete(:stop)

            # Filter to known keys only
            filtered = h.slice(*PARAMS_KNOWN_KEYS)

            # Return nil if all known values are nil
            return nil if filtered.all? { |_, v| v.nil? }

            new(
              max_tokens: filtered[:max_tokens],
              max_thinking_tokens: filtered[:max_thinking_tokens],
              temperature: filtered[:temperature],
              top_p: filtered[:top_p],
              top_k: filtered[:top_k],
              stop_sequences: filtered[:stop_sequences],
              seed: filtered[:seed],
              frequency_penalty: filtered[:frequency_penalty],
              presence_penalty: filtered[:presence_penalty],
              response_format: filtered[:response_format]
            )
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            super.compact
          end
        end
        # rubocop:enable Lint/ConstantDefinitionInBlock
      end
    end
  end
end
# rubocop:enable Metrics/PerceivedComplexity
