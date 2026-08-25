# frozen_string_literal: true

# -- extracted from thinking.rb; depends on Thinking being defined first
module Legion
  module Extensions
    # -- module doc is in canonical.rb entry point
    module Llm
      # -- required for Data.define block scope
      module Canonical
        # Normalized config for thinking across providers — one name, one shape
        # (04 §8): Canonical::Thinking::Config.
        # Members: enabled, effort, budget, summary, metadata
        Thinking::Config = ::Data.define(:enabled, :effort, :budget, :summary, :metadata) do
          def self.build(enabled: true, effort: nil, budget: nil, summary: nil, metadata: {})
            new(enabled: enabled, effort: effort_string!(effort, self::BUILD_SITE), budget: budget,
                summary: summary, metadata: Strict.metadata!(metadata, self::BUILD_SITE))
          end

          # Build from a Hash.
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(enabled: hash.key?(:enabled) ? hash[:enabled] : true,
                  effort: hash[:effort], budget: hash[:budget],
                  summary: hash[:summary], metadata: metadata)
          end

          # M4: effort is a closed enum (the EFFORT_BUDGET keys), not an
          # unbounded string — an unrecognized effort is a contract error at
          # construction, never a silently-derived budget.
          def self.effort_string!(effort, site)
            return nil if effort.nil?

            value = effort.is_a?(::Symbol) ? effort.to_s : Strict.expect_type!(effort, [::String], site, :effort)
            normalized = value.downcase
            allowed = self::EFFORT_LEVELS
            raise ArgumentError, "#{site}: Invalid effort: #{value.inspect}. Must be one of: #{allowed.join(', ')}" unless allowed.include?(normalized)

            normalized
          end

          # Validate summary is a closed enum.
          def self.summary_enum!(value, site)
            return nil if value.nil?

            sym = value.is_a?(::String) ? value.to_sym : value
            Strict.expect_type!(sym, [::Symbol], site, :summary)
            allowed = self::SUMMARY_LEVELS
            unless allowed.include?(sym)
              raise ArgumentError,
                    "#{site}: Invalid summary: #{value.inspect}. Must be one of: #{allowed.map(&:inspect).join(', ')}"
            end

            sym
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

          # Whether thinking is enabled (the enabled member).
          def enabled?
            enabled
          end

          # Budget for a provider that needs a token budget (e.g. Anthropic),
          # derived from effort when budget was not explicitly set. nil when
          # effort is 'none' or neither axis is configured. Only FILLS — never
          # overwrites a supplied budget. Both axes may be carried together.
          def resolved_budget
            return budget unless budget.nil?
            return nil if effort.nil?
            return nil if effort == 'none'

            self.class::EFFORT_BUDGET[effort]
          end

          # Effort for a provider that needs an effort level (e.g. OpenAI),
          # derived from budget when effort was not explicitly set. nil only
          # when neither axis is configured. Only FILLS — never overwrites a
          # supplied effort.
          def resolved_effort
            return effort unless effort.nil?
            return nil if budget.nil?

            bands = self.class::EFFORT_BUDGET
            if budget <= bands['low'] then 'low'
            elsif budget <= bands['medium'] then 'medium'
            elsif budget <= bands['high'] then 'high'
            elsif budget <= bands['xhigh'] then 'xhigh'
            else 'max'
            end
          end

          # H1/M4: the single strict constructor — .new runs the same member
          # contract as the factories (enabled bool, effort enum, Integer budget,
          # summary enum); the factories fill their defaults and delegate here.
          Strict.install_strict_new!(self) do |values, site|
            # enabled: must be true or false
            raise ArgumentError, "#{site}: enabled must be true or false, got #{values[:enabled].inspect}" unless [true, false].include?(values[:enabled])

            values[:effort] = effort_string!(values[:effort], site)

            # budget: must be a positive Integer or nil
            values[:budget] = Strict.expect_type!(values[:budget], [::Integer], site, :budget)
            raise ArgumentError, "#{site}: budget must be positive, got #{values[:budget]}" if values[:budget] && !values[:budget].positive?

            values[:summary] = summary_enum!(values[:summary], site)
            values[:metadata] = Strict.metadata!(values[:metadata], site)
            values
          end
        end

        # Closed set of valid effort levels.
        Thinking::Config::EFFORT_LEVELS = %w[none low medium high xhigh max].freeze

        # SSOT for the effort<->budget conversion. A client dialect supplies only
        # ONE axis (Anthropic = budget_tokens only; OpenAI = effort only), but a
        # provider translator may need the OTHER. This single map lets every
        # provider ask for whichever axis it needs and always get a usable value,
        # so thinking survives any client x provider pair (best-effort, never
        # silently dropped). effort -> budget is exact; budget -> effort uses the
        # band boundaries above. 'none' has no budget — resolves to nil.
        Thinking::Config::EFFORT_BUDGET = {
          'low' => 1024, 'medium' => 8192, 'high' => 16_384,
          'xhigh' => 24_576, 'max' => 32_768
        }.freeze

        # Closed set of valid summary levels.
        Thinking::Config::SUMMARY_LEVELS = %i[auto none concise detailed].freeze

        Thinking::Config::BUILD_SITE = 'Canonical::Thinking::Config.build'
        Thinking::Config::FROM_HASH_SITE = 'Canonical::Thinking::Config.from_hash'
        Thinking::Config::NEW_SITE = 'Canonical::Thinking::Config.new'
      end
    end
  end
end
