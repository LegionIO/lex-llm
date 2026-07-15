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

          # MultiJson/Oj/::JSON callback — prevents Data.define #inspect leak into JSON.
          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
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

          # SSOT for the effort<->budget conversion. A client dialect supplies only
          # ONE axis (Anthropic = budget_tokens only; OpenAI = effort only), but a
          # provider translator may need the OTHER. This single map lets every
          # provider ask for whichever axis it needs and always get a usable value,
          # so thinking survives any client x provider pair (best-effort, never
          # silently dropped). effort -> budget is exact; budget -> effort uses the
          # band boundaries below.
          EFFORT_BUDGET = { 'low' => 1024, 'medium' => 8192, 'high' => 16_384 }.freeze

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

          # Serialize to a Hash for AMQP/fleet/wire transport. Faithful to what was
          # SET — never fabricates the missing axis (use resolved_* for that).
          def to_h
            { effort: effort, budget: budget }.compact
          end

          # Whether thinking is configured.
          def enabled?
            !effort.nil? || !budget.nil?
          end

          # Budget for a provider that needs a token budget (e.g. Anthropic),
          # derived from effort when budget was not explicitly set. nil only when
          # neither axis is configured.
          def resolved_budget
            return budget unless budget.nil?
            return nil if effort.nil?

            EFFORT_BUDGET[effort.to_s.downcase] || EFFORT_BUDGET['medium']
          end

          # Effort for a provider that needs an effort level (e.g. OpenAI),
          # derived from budget when effort was not explicitly set. nil only when
          # neither axis is configured.
          def resolved_effort
            return effort unless effort.nil?
            return nil if budget.nil?

            b = budget.to_i
            if b < EFFORT_BUDGET['medium'] then 'low'
            elsif b < EFFORT_BUDGET['high'] then 'medium'
            else 'high'
            end
          end
        end

        # Alias for convenience: Canonical::Thinking::Config
        Thinking.const_set(:Config, ThinkingConfig)
      end
      # rubocop:enable Style/Documentation
    end
  end
end
