# frozen_string_literal: true

# -- from_hash normalization is intentional
module Legion
  module Extensions
    module Llm
      module Canonical
        # rubocop:disable Lint/ConstantDefinitionInBlock -- required for Data.define block scope
        # Canonical usage/metering data for a response.
        # Ports field vocabulary from lex-llm Tokens and legion-llm Types.
        # Includes non-token units extension point per G20b.
        Usage = ::Data.define(
          :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens,
          :thinking_tokens, :units
        ) do
          USAGE_KNOWN_KEYS = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens
                                thinking_tokens units].freeze

          # Build from a Hash (raw provider response or deserialized wire payload).
          # Accepts both canonical key names and legacy provider spellings.
          def self.from_hash(source)
            return nil if source.nil? || source.empty?

            h = source.transform_keys(&:to_sym)

            # Normalize legacy key names
            h[:input_tokens] ||= h.delete(:input) || h.delete(:prompt_tokens)
            h[:output_tokens] ||= h.delete(:output) || h.delete(:completion_tokens)
            h[:cache_read_tokens] ||= h.delete(:cached) || h.delete(:cache_read)
            h[:cache_write_tokens] ||= h.delete(:cache_creation) || h.delete(:cache_write)
            h[:thinking_tokens] ||= h.delete(:thinking) || h.delete(:reasoning)

            # Extract nested details (OpenAI prompt_tokens_details / input_tokens_details)
            h[:cache_read_tokens] ||= dig_nested(h, :prompt_tokens_details, :cached_tokens) ||
                                      dig_nested(h, :input_tokens_details, :cached_tokens)
            h[:thinking_tokens] ||= dig_nested(h, :completion_tokens_details, :reasoning_tokens) ||
                                    dig_nested(h, :output_tokens_details, :reasoning_tokens)

            # Extract units (non-token extension point — G20b)
            units = h.delete(:units) || {}

            new(
              input_tokens: h[:input_tokens],
              output_tokens: h[:output_tokens],
              cache_read_tokens: h[:cache_read_tokens],
              cache_write_tokens: h[:cache_write_tokens],
              thinking_tokens: h[:thinking_tokens],
              units: units
            )
          end

          def self.dig_nested(hash, details_key, value_key)
            details = hash[details_key]
            return nil unless details.is_a?(Hash)

            details[value_key] || details[value_key.to_s]
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            super.compact
          end

          # Total tokens across all categories.
          def total_tokens
            [input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
             thinking_tokens].compact.sum
          end
        end
        # rubocop:enable Lint/ConstantDefinitionInBlock
      end
    end
  end
end
