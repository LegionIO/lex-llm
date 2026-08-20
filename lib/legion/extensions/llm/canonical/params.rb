# frozen_string_literal: true

# -- from_hash normalization is intentional
module Legion
  module Extensions
    # -- module doc is in canonical.rb entry point
    module Llm
      # -- required for Data.define block scope
      module Canonical
        # Canonical sampling and limit parameters for a request.
        # Per G18: all standard/useful params are first-class, mapped per provider by translators.
        # Canonical keys only (O03a): provider spellings are translated at the edges.
        Params = ::Data.define(
          :max_tokens, :max_thinking_tokens, :temperature, :top_p, :top_k,
          :stop_sequences, :seed, :frequency_penalty, :presence_penalty,
          :response_format, :metadata
        ) do
          # rubocop:disable Metrics/ParameterLists -- factory methods have many params
          # Build from keyword args (primary constructor).
          def self.build(
            max_tokens: nil, max_thinking_tokens: nil, temperature: nil, top_p: nil, top_k: nil,
            stop_sequences: nil, seed: nil, frequency_penalty: nil, presence_penalty: nil,
            response_format: nil, metadata: {}
          )
            new(
              max_tokens:, max_thinking_tokens:, temperature:, top_p:, top_k:,
              stop_sequences:, seed:, frequency_penalty:, presence_penalty:,
              response_format:, metadata: Strict.metadata!(metadata, self::BUILD_SITE)
            )
          end
          # rubocop:enable Metrics/ParameterLists

          # Build from a Hash (raw client request or deserialized wire payload).
          # Canonical member keys only; unknown keys fold into metadata (04 L5).
          # from_hash({}) is a valid all-nil Params (the no-params object), never nil.
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(
              max_tokens: hash[:max_tokens],
              max_thinking_tokens: hash[:max_thinking_tokens],
              temperature: hash[:temperature],
              top_p: hash[:top_p],
              top_k: hash[:top_k],
              stop_sequences: hash[:stop_sequences],
              seed: hash[:seed],
              frequency_penalty: hash[:frequency_penalty],
              presence_penalty: hash[:presence_penalty],
              response_format: hash[:response_format],
              metadata:
            )
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            super.compact
          end

          # MultiJson/Oj/::JSON callback — prevents Data.define #inspect leak into JSON.
          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
          end
        end

        Params::BUILD_SITE = 'Canonical::Params.build'
        Params::FROM_HASH_SITE = 'Canonical::Params.from_hash'
      end
    end
  end
end
