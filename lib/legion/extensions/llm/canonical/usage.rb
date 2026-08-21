# frozen_string_literal: true

# -- from_hash normalization is intentional
module Legion
  module Extensions
    module Llm
      # -- required for Data.define block scope
      module Canonical
        # Canonical usage/metering data for a response.
        # Ports field vocabulary from lex-llm Tokens and legion-llm Types.
        # Includes non-token units extension point per G20b.
        # Canonical keys only (O03a): provider spellings are translated at the edges.
        Usage = ::Data.define(
          :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens,
          :thinking_tokens, :units, :metadata
        ) do
          # rubocop:disable Metrics/ParameterLists -- factory methods have many params
          # Build from keyword args (primary constructor).
          def self.build(
            input_tokens: nil, output_tokens: nil, cache_read_tokens: nil,
            cache_write_tokens: nil, thinking_tokens: nil, units: nil, metadata: {}
          )
            new(
              input_tokens:, output_tokens:, cache_read_tokens:, cache_write_tokens:,
              thinking_tokens:, units: units || {}, metadata: Strict.metadata!(metadata, self::BUILD_SITE)
            )
          end
          # rubocop:enable Metrics/ParameterLists

          # Build from a Hash (raw provider response or deserialized wire payload).
          # from_hash({}) is a valid all-nil Usage (the no-usage object), never nil.
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(
              input_tokens: hash[:input_tokens],
              output_tokens: hash[:output_tokens],
              cache_read_tokens: hash[:cache_read_tokens],
              cache_write_tokens: hash[:cache_write_tokens],
              thinking_tokens: hash[:thinking_tokens],
              units: hash[:units] || {},
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

          # Total tokens across all categories.
          def total_tokens
            [input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
             thinking_tokens].compact.sum
          end

          # H1/M3: the single strict constructor. .new validates the token
          # members as Integers (a string count would raise deep in
          # StreamAccumulator#total_tokens instead of at construction) and
          # units as a Hash. The factories fill their defaults and delegate
          # here.
          Strict.install_strict_new!(self) do |values, site|
            values[:input_tokens] = Strict.expect_type!(values[:input_tokens], [::Integer], site, :input_tokens)
            values[:output_tokens] = Strict.expect_type!(values[:output_tokens], [::Integer], site, :output_tokens)
            values[:cache_read_tokens] = Strict.expect_type!(values[:cache_read_tokens], [::Integer], site, :cache_read_tokens)
            values[:cache_write_tokens] = Strict.expect_type!(values[:cache_write_tokens], [::Integer], site, :cache_write_tokens)
            values[:thinking_tokens] = Strict.expect_type!(values[:thinking_tokens], [::Integer], site, :thinking_tokens)
            values[:units] = values[:units].nil? ? {} : Strict.expect_type!(values[:units], [::Hash], site, :units)
            values[:metadata] = Strict.metadata!(values[:metadata], site)
            values
          end
        end

        Usage::BUILD_SITE = 'Canonical::Usage.build'
        Usage::FROM_HASH_SITE = 'Canonical::Usage.from_hash'
        Usage::NEW_SITE = 'Canonical::Usage.new'
      end
    end
  end
end
