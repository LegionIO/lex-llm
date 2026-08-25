# frozen_string_literal: true

# -- extracted from thinking.rb; depends on Thinking being defined first
module Legion
  module Extensions
    # -- module doc is in canonical.rb entry point
    module Llm
      # -- required for Data.define block scope
      module Canonical
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

          # M4: effort is a closed enum (the EFFORT_BUDGET keys), not an
          # unbounded string — an unrecognized effort is a contract error at
          # construction, never a silently-derived budget.
          def self.effort_string!(effort, site)
            return nil if effort.nil?

            value = effort.is_a?(::Symbol) ? effort.to_s : Strict.expect_type!(effort, [::String], site, :effort)
            normalized = value.downcase
            allowed = self::EFFORT_BUDGET.keys
            raise ArgumentError, "#{site}: Invalid effort: #{value.inspect}. Must be one of: #{allowed.join(', ')}" unless allowed.include?(normalized)

            normalized
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
          # derived from effort when budget was not explicitly set. nil only
          # when neither axis is configured. M4: effort is enum-validated at
          # construction, so the lookup cannot miss — the silent medium
          # fallback is deleted.
          def resolved_budget
            return budget unless budget.nil?
            return nil if effort.nil?

            self.class::EFFORT_BUDGET[effort]
          end

          # Effort for a provider that needs an effort level (e.g. OpenAI),
          # derived from budget when effort was not explicitly set. nil only
          # when neither axis is configured.
          def resolved_effort
            return effort unless effort.nil?
            return nil if budget.nil?

            bands = self.class::EFFORT_BUDGET
            if budget < bands['medium'] then 'low'
            elsif budget < bands['high'] then 'medium'
            else 'high'
            end
          end

          # H1/M4: the single strict constructor — .new runs the same member
          # contract as the factories (effort enum, Integer budget); the
          # factories fill their defaults and delegate here.
          Strict.install_strict_new!(self) do |values, site|
            values[:effort] = effort_string!(values[:effort], site)
            values[:budget] = Strict.expect_type!(values[:budget], [::Integer], site, :budget)
            values[:metadata] = Strict.metadata!(values[:metadata], site)
            values
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
        Thinking::Config::NEW_SITE = 'Canonical::Thinking::Config.new'
      end
    end
  end
end
