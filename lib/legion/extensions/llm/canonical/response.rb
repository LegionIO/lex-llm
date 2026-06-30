# frozen_string_literal: true

# rubocop:disable Metrics/ParameterLists -- factory methods have many params
module Legion
  module Extensions
    module Llm
      module Canonical
        # rubocop:disable Lint/ConstantDefinitionInBlock -- required for Data.define block scope
        # Canonical response shape — the provider-boundary contract.
        # Per R2: does NOT replace Inference::Response (the pipeline envelope).
        # Per Amendment A: immutable Data.define with strict factory.
        Response = ::Data.define(
          :text, :thinking, :tool_calls, :usage,
          :stop_reason, :model, :routing, :metadata
        ) do
          STOP_REASONS = %i[end_turn tool_use max_tokens stop_sequence content_filter error].freeze

          # Build from a Hash (raw provider response or deserialized wire payload).
          # Unknown keys go to metadata, never silently dropped.
          def self.from_hash(source)
            return nil if source.nil?

            h = source.transform_keys(&:to_sym)

            # Extract known fields
            text = h.delete(:text) || h.delete(:content) || ''
            text = text.to_s if text

            thinking_raw = h.delete(:thinking)
            thinking = thinking_raw.is_a?(Thinking) ? thinking_raw : Thinking.from_hash(thinking_raw)

            tool_calls_raw = h.delete(:tool_calls)
            tool_calls = Array(tool_calls_raw).filter_map do |tc|
              tc.is_a?(ToolCall) ? tc : ToolCall.from_hash(tc)
            end

            usage_raw = h.delete(:usage)
            usage = usage_raw.is_a?(Usage) ? usage_raw : Usage.from_hash(usage_raw)

            # Normalize stop_reason
            stop_reason_raw = h.delete(:stop_reason) || h.delete(:finish_reason)
            stop_reason = stop_reason_raw&.to_sym if stop_reason_raw
            unless stop_reason.nil? || STOP_REASONS.include?(stop_reason)
              raise ArgumentError,
                    "Invalid stop_reason: #{stop_reason.inspect}. Must be one of: #{STOP_REASONS.join(', ')}"
            end

            model = h.delete(:model)
            routing = h.delete(:routing) || {}

            # Remaining keys become metadata
            existing_metadata = h.delete(:metadata) || {}
            metadata = existing_metadata.merge(h).compact

            new(
              text: text,
              thinking: thinking,
              tool_calls: tool_calls,
              usage: usage,
              stop_reason: stop_reason,
              model: model,
              routing: routing,
              metadata: metadata
            )
          end

          # Build from keyword args (primary constructor).
          def self.build(
            text: '', thinking: nil, tool_calls: nil, usage: nil,
            stop_reason: nil, model: nil, routing: nil, metadata: nil
          )
            stop_reason_sym = stop_reason&.to_sym
            unless stop_reason_sym.nil? || STOP_REASONS.include?(stop_reason_sym)
              raise ArgumentError,
                    "Invalid stop_reason: #{stop_reason_sym.inspect}. Must be one of: #{STOP_REASONS.join(', ')}"
            end

            new(
              text: text.to_s,
              thinking: thinking,
              tool_calls: tool_calls || [],
              usage: usage,
              stop_reason: stop_reason_sym,
              model: model,
              routing: routing || {},
              metadata: metadata || {}
            )
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            {
              text: text,
              thinking: thinking&.to_h,
              tool_calls: tool_calls&.map { |tc| tc.is_a?(ToolCall) ? tc.to_h : tc },
              usage: usage&.to_h,
              stop_reason: stop_reason,
              model: model,
              routing: routing,
              metadata: metadata
            }.compact.reject do |k, v|
              %i[tool_calls routing
                 metadata].include?(k) && v.is_a?(Enumerable) && v.empty?
            end
          end

          # MultiJson/Oj/::JSON callback — prevents Data.define #inspect leak into JSON.
          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
          end

          # Whether the response includes tool calls.
          def tool_call?
            !tool_calls.nil? && !tool_calls.empty?
          end

          # Whether the response ended due to an error.
          def error?
            stop_reason == :error
          end
        end

        Response::STOP_REASONS = %i[end_turn tool_use max_tokens stop_sequence content_filter error].freeze
        # rubocop:enable Lint/ConstantDefinitionInBlock
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
