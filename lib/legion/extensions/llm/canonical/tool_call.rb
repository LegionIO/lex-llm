# frozen_string_literal: true

require 'securerandom'

# rubocop:disable Metrics/ParameterLists -- factory methods have many params
module Legion
  module Extensions
    module Llm
      # -- required for Data.define block scope
      module Canonical
        # Canonical tool call with source enum and compliance fields.
        # Ports field vocabulary from Legion::LLM::Types::ToolCall.
        # Source enum per R7: :client | :registry | :special | :extension | :mcp
        # Compliance fields per R8: data_handling_classification, policy_decision
        # arguments is a Hash only (O03a): JSON-string arguments are a provider
        # wire spelling parsed at the provider translator edge (10 U2).
        ToolCall = ::Data.define(
          :id, :exchange_id, :name, :arguments, :source,
          :status, :duration_ms, :result, :error,
          :started_at, :finished_at, :category,
          :data_handling_classification, :policy_decision, :metadata
        ) do
          # Build from keyword args (primary constructor).
          # arguments: nil means "no arguments" and normalizes to {} (documented
          # default, not tolerance).
          def self.build(
            name:, id: nil, exchange_id: nil, arguments: nil, source: nil,
            status: nil, duration_ms: nil, result: nil, error: nil,
            started_at: nil, finished_at: nil, category: nil,
            data_handling_classification: nil, policy_decision: nil, metadata: {}
          )
            new(
              id: id || "call_#{SecureRandom.hex(12)}",
              exchange_id: exchange_id,
              name: Strict.expect_type!(name, [::String], self::BUILD_SITE, :name),
              arguments: arguments.nil? ? {} : Strict.expect_type!(arguments, [::Hash], self::BUILD_SITE, :arguments),
              source: normalize_enum!(source, self::SOURCE_VALUES, self::BUILD_SITE, :source),
              status: normalize_enum!(status, self::STATUS_VALUES, self::BUILD_SITE, :status),
              duration_ms: duration_ms,
              result: result,
              error: error,
              started_at: started_at,
              finished_at: finished_at,
              category: category,
              data_handling_classification: data_handling_classification,
              policy_decision: policy_decision,
              metadata: Strict.metadata!(metadata, self::BUILD_SITE)
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(**hash, metadata:)
          end

          # L6: declared enums validated at construction, in both factories.
          def self.normalize_enum!(value, allowed, site, member)
            return nil if value.nil?

            value_sym = value.is_a?(::String) ? value.to_sym : value
            Strict.enum!(value_sym, allowed, site, member)
          end

          # Return a new ToolCall with execution result attached.
          def with_result(result:, status:, duration_ms: nil, finished_at: nil)
            self.class.new(
              id: id,
              exchange_id: exchange_id,
              name: name,
              arguments: arguments,
              source: source,
              status: Strict.enum!(status, self.class::STATUS_VALUES, 'Canonical::ToolCall.with_result', :status),
              duration_ms: duration_ms,
              result: result,
              error: status == :error ? result : error,
              started_at: started_at,
              finished_at: finished_at || ::Time.now,
              category: category,
              data_handling_classification: data_handling_classification,
              policy_decision: policy_decision,
              metadata: metadata
            )
          end

          def success?
            status == :success
          end

          def error?
            status == :error
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            super.compact
          end

          # MultiJson/Oj/::JSON callback for unknown types — without this, fallback is
          # obj.to_s which for Data.define returns the #inspect dump and leaks into JSON.
          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
          end
        end

        ToolCall::SOURCE_VALUES = %i[client registry special extension mcp].freeze
        ToolCall::STATUS_VALUES = %i[pending running success error].freeze
        ToolCall::BUILD_SITE = 'Canonical::ToolCall.build'
        ToolCall::FROM_HASH_SITE = 'Canonical::ToolCall.from_hash'
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
