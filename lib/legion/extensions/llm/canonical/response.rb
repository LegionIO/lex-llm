# frozen_string_literal: true

# rubocop:disable Metrics/ParameterLists -- factory methods have many params
module Legion
  module Extensions
    module Llm
      # -- required for Data.define block scope
      module Canonical
        # Canonical response shape — the provider-boundary contract.
        # Per R2: does NOT replace Inference::Response (the pipeline envelope).
        # Per Amendment A: immutable Data.define with strict factory.
        # Unknown keys fold into metadata — never silently dropped.
        Response = ::Data.define(
          :text, :thinking, :tool_calls, :usage,
          :stop_reason, :model, :routing, :metadata
        ) do
          # Build from keyword args (primary constructor).
          def self.build(
            text: '', thinking: nil, tool_calls: nil, usage: nil,
            stop_reason: nil, model: nil, routing: nil, metadata: {}
          )
            new(
              text: text.to_s,
              thinking: normalize_thinking!(thinking, self::BUILD_SITE),
              tool_calls: normalize_tool_calls!(tool_calls, self::BUILD_SITE),
              usage: normalize_usage!(usage, self::BUILD_SITE),
              stop_reason: normalize_stop_reason!(stop_reason, self::BUILD_SITE),
              model: model,
              routing: routing || {},
              metadata: Strict.metadata!(metadata, self::BUILD_SITE)
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          # Canonical keys only (O03a): edges pass `stop_reason`, not `finish_reason`.
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(**hash, metadata:)
          end

          # L6: stop_reason validated at construction, in both factories.
          def self.normalize_stop_reason!(stop_reason, site)
            stop_reason_sym = stop_reason&.to_sym
            Strict.enum!(stop_reason_sym, self::STOP_REASONS, site, :stop_reason)
          end

          # L2: one normalizer per member, shared by build and from_hash.
          def self.normalize_thinking!(thinking, site)
            return nil if thinking.nil?
            return thinking if thinking.is_a?(Thinking)

            Strict.expect_type!(thinking, [::Hash], site, :thinking)
            Thinking.from_hash(thinking)
          end

          def self.normalize_tool_calls!(tool_calls, site)
            return [] if tool_calls.nil?

            Strict.expect_type!(tool_calls, [::Array], site, :tool_calls)
            tool_calls.map { |tc| tc.is_a?(ToolCall) ? tc : ToolCall.from_hash(tc) }
          end

          def self.normalize_usage!(usage, site)
            return nil if usage.nil?
            return usage if usage.is_a?(Usage)

            Strict.expect_type!(usage, [::Hash], site, :usage)
            Usage.from_hash(usage)
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

          # Whether the response includes tool calls.
          def tool_call?
            !tool_calls.nil? && !tool_calls.empty?
          end

          # Whether the response ended due to an error.
          def error?
            stop_reason == :error
          end

          # H1: the single strict constructor — .new runs the same member
          # contract as the factories; the factories fill their defaults and
          # delegate here.
          Strict.install_strict_new!(self) do |values, site|
            values[:thinking] = normalize_thinking!(values[:thinking], site)
            values[:tool_calls] = normalize_tool_calls!(values[:tool_calls], site)
            values[:usage] = normalize_usage!(values[:usage], site)
            values[:stop_reason] = normalize_stop_reason!(values[:stop_reason], site)
            values[:metadata] = Strict.metadata!(values[:metadata], site)
            values
          end
        end

        Response::STOP_REASONS = %i[end_turn tool_use max_tokens stop_sequence content_filter error].freeze
        Response::BUILD_SITE = 'Canonical::Response.build'
        Response::FROM_HASH_SITE = 'Canonical::Response.from_hash'
        Response::NEW_SITE = 'Canonical::Response.new'
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
