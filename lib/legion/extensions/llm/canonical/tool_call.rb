# frozen_string_literal: true

require 'securerandom'

# rubocop:disable Metrics/ParameterLists, -- factory methods have many params
module Legion
  module Extensions
    module Llm
      module Canonical
        # rubocop:disable Lint/ConstantDefinitionInBlock -- required for Data.define block scope
        # Canonical tool call with source enum and compliance fields.
        # Ports field vocabulary from Legion::LLM::Types::ToolCall.
        # Source enum per R7: :client | :registry | :special | :extension | :mcp
        # Compliance fields per R8: data_handling_classification, policy_decision
        ToolCall = ::Data.define(
          :id, :exchange_id, :name, :arguments, :source,
          :status, :duration_ms, :result, :error,
          :started_at, :finished_at, :category,
          :data_handling_classification, :policy_decision
        ) do
          SOURCE_VALUES = %i[client registry special extension mcp].freeze
          STATUS_VALUES = %i[pending running success error].freeze

          # Build from keyword args (primary constructor).
          def self.build(
            name:, id: nil, exchange_id: nil, arguments: nil, source: nil,
            status: nil, duration_ms: nil, result: nil, error: nil,
            started_at: nil, finished_at: nil, category: nil,
            data_handling_classification: nil, policy_decision: nil
          )
            new(
              id: id || "call_#{SecureRandom.hex(12)}",
              exchange_id: exchange_id,
              name: name,
              arguments: arguments || {},
              source: source,
              status: status,
              duration_ms: duration_ms,
              result: result,
              error: error,
              started_at: started_at,
              finished_at: finished_at,
              category: category,
              data_handling_classification: data_handling_classification,
              policy_decision: policy_decision
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          def self.from_hash(hash)
            return nil if hash.nil?

            h = hash.transform_keys(&:to_sym)

            # Normalize source to symbol
            source_raw = h[:source]
            h[:source] = source_raw&.to_sym if source_raw.is_a?(String)

            # Normalize status to symbol
            status_raw = h[:status]
            h[:status] = status_raw&.to_sym if status_raw.is_a?(String)

            # Parse arguments if they're a JSON string
            args = h[:arguments]
            if args.is_a?(String) && !args.empty?
              begin
                h[:arguments] = ::JSON.parse(args)
              rescue JSON::ParserError
                # Leave as-is; downstream will handle malformed args
              end
            end

            build(**h)
          end

          # Return a new ToolCall with execution result attached.
          def with_result(result:, status:, duration_ms: nil, finished_at: nil)
            self.class.new(
              id: id,
              exchange_id: exchange_id,
              name: name,
              arguments: arguments,
              source: source,
              status: status,
              duration_ms: duration_ms,
              result: result,
              error: status == :error ? result : error,
              started_at: started_at,
              finished_at: finished_at || ::Time.now,
              category: category,
              data_handling_classification: data_handling_classification,
              policy_decision: policy_decision
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

          # Subset for audit/ledger emission.
          def to_audit_hash
            {
              id: id,
              name: name,
              arguments: arguments,
              status: status,
              duration_ms: duration_ms,
              error: error,
              exchange_id: exchange_id,
              source: source,
              category: category,
              data_handling_classification: data_handling_classification,
              policy_decision: policy_decision
            }.compact
          end
        end

        ToolCall::SOURCE_VALUES = %i[client registry special extension mcp].freeze
        ToolCall::STATUS_VALUES = %i[pending running success error].freeze
        # rubocop:enable Lint/ConstantDefinitionInBlock
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
