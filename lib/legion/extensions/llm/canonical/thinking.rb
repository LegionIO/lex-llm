# frozen_string_literal: true

# -- from_hash normalization is intentional
module Legion
  module Extensions
    # -- module doc is in canonical.rb entry point
    module Llm
      # -- required for Data.define block scope
      module Canonical
        # Canonical thinking/reasoning block.
        # Ports field vocabulary from Legion::LLM::Types and lex-llm Thinking.
        # Empty-string values normalize to nil (absence, not data — 04 §8).
        Thinking = ::Data.define(:content, :signature, :metadata) do
          # Build from keyword args (primary constructor).
          def self.build(content: nil, signature: nil, metadata: {})
            new(
              content: absence!(content, self::BUILD_SITE, :content),
              signature: absence!(signature, self::BUILD_SITE, :signature),
              metadata: Strict.metadata!(metadata, self::BUILD_SITE)
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(content: hash[:content], signature: hash[:signature], metadata:)
          end

          # Empty-string is absence, not data (04 §8).
          def self.absence!(value, site, member)
            return nil if value.nil?

            Strict.expect_type!(value, [::String], site, member)
            value.empty? ? nil : value
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

        Thinking::BUILD_SITE = 'Canonical::Thinking.build'
        Thinking::FROM_HASH_SITE = 'Canonical::Thinking.from_hash'

        # Normalized config for thinking across providers — one name, one shape
        # (04 §8): Canonical::Thinking::Config. # -- required for Data.define block scope
        Thinking::Config = ::Data.define(:effort, :budget, :metadata) do
          def self.build(effort: nil, budget: nil, metadata: {})
            new(effort: effort_string!(effort, self::BUILD_SITE), budget:,
                metadata: Strict.metadata!(metadata, self::BUILD_SITE))
          end

          # Build from a Hash.
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(effort: hash[:effort], budget: hash[:budget], metadata:)
          end

          def self.effort_string!(effort, site)
            return nil if effort.nil?
            return effort.to_s if effort.is_a?(::Symbol)

            Strict.expect_type!(effort, [::String], site, :effort)
          end

          # Serialize to a Hash for AMQP/fleet/wire transport. Faithful to what was
          # SET — never fabricates the missing axis (use resolved_* for that).
          def to_h
            super.compact
          end

          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
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

            self.class::EFFORT_BUDGET[effort.to_s.downcase] || self.class::EFFORT_BUDGET['medium']
          end

          # Effort for a provider that needs an effort level (e.g. OpenAI),
          # derived from budget when effort was not explicitly set. nil only when
          # neither axis is configured.
          def resolved_effort
            return effort unless effort.nil?
            return nil if budget.nil?

            bands = self.class::EFFORT_BUDGET
            b = budget.to_i
            if b < bands['medium'] then 'low'
            elsif b < bands['high'] then 'medium'
            else 'high'
            end
          end
        end

        # SSOT for the effort<->budget conversion. A client dialect supplies only
        # ONE axis (Anthropic = budget_tokens only; OpenAI = effort only), but a
        # provider translator may need the OTHER. This single map lets every
        # provider ask for whichever axis it needs and always get a usable value,
        # so thinking survives any client x provider pair (best-effort, never
        # silently dropped). effort -> budget is exact; budget -> effort uses the
        # band boundaries above.
        Thinking::Config::EFFORT_BUDGET = { 'low' => 1024, 'medium' => 8192, 'high' => 16_384 }.freeze
        Thinking::Config::BUILD_SITE = 'Canonical::Thinking::Config.build'
        Thinking::Config::FROM_HASH_SITE = 'Canonical::Thinking::Config.from_hash'
      end
    end
  end
end
