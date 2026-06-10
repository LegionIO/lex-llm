# frozen_string_literal: true

# -- from_hash normalization is intentional
module Legion
  module Extensions
    module Llm
      # rubocop:disable Style/Documentation -- module doc is in canonical.rb entry point
      module Canonical
        # Canonical thinking/reasoning block.
        # Ports field vocabulary from Legion::LLM::Types and lex-llm Thinking.
        Thinking = ::Data.define(:content, :signature) do
          # Build from a Hash (raw provider response or deserialized wire payload).
          def self.from_hash(source)
            return nil if source.nil?

            h = source.transform_keys(&:to_sym)

            # Treat empty strings as nil
            content = h[:content]
            content = nil if content.is_a?(String) && content.empty?
            signature = h[:signature]
            signature = nil if signature.is_a?(String) && signature.empty?

            return nil if content.nil? && signature.nil?

            new(content: content, signature: signature)
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            super.compact
          end

          # Whether this thinking block has any content.
          def empty?
            content.nil? && signature.nil?
          end
        end

        # Normalized config for thinking across providers.
        # Mirrors lex-llm Thinking::Config.
        class ThinkingConfig
          INCLUDES = Thinking
          attr_reader :effort, :budget

          def initialize(effort: nil, budget: nil)
            @effort = effort.is_a?(Symbol) ? effort.to_s : effort
            @budget = budget
          end

          # Build from keyword args.
          def self.build(effort: nil, budget: nil)
            new(effort: effort, budget: budget)
          end

          # Build from a Hash.
          def self.from_hash(source)
            return nil if source.nil? || source.empty?

            h = source.transform_keys(&:to_sym)
            build(effort: h[:effort], budget: h[:budget])
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            { effort: effort, budget: budget }.compact
          end

          # Whether thinking is configured.
          def enabled?
            !effort.nil? || !budget.nil?
          end
        end

        # Alias for convenience: Canonical::Thinking::Config
        Thinking.const_set(:Config, ThinkingConfig)
      end
      # rubocop:enable Style/Documentation
    end
  end
end
