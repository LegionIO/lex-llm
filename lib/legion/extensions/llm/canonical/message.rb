# frozen_string_literal: true

require 'securerandom'

# rubocop:disable Metrics/ParameterLists, Metrics/PerceivedComplexity -- factory methods have many params
module Legion
  module Extensions
    module Llm
      module Canonical
        # rubocop:disable Lint/ConstantDefinitionInBlock -- required for Data.define block scope
        # Canonical message in a conversation.
        # Ports field vocabulary from Legion::LLM::Types::Message and lex-llm Message.
        Message = ::Data.define(
          :id, :parent_id, :role, :content, :tool_calls, :tool_call_id,
          :name, :status, :version, :timestamp, :seq,
          :provider, :model, :input_tokens, :output_tokens,
          :conversation_id, :task_id
        ) do
          ROLES = %i[system user assistant tool].freeze

          # Build from keyword args (primary constructor).
          def self.build(
            id: nil, parent_id: nil, role: :user, content: nil, tool_calls: nil,
            tool_call_id: nil, name: nil, status: :created, version: 1,
            timestamp: nil, seq: nil, provider: nil, model: nil,
            input_tokens: nil, output_tokens: nil, conversation_id: nil, task_id: nil
          )
            role_sym = role.is_a?(String) ? role.to_sym : role
            unless ROLES.include?(role_sym)
              raise ArgumentError,
                    "Invalid role: #{role_sym}. Must be one of: #{ROLES.join(', ')}"
            end

            new(
              id: id || "msg_#{SecureRandom.hex(12)}",
              parent_id: parent_id,
              role: role_sym,
              content: content,
              tool_calls: tool_calls,
              tool_call_id: tool_call_id,
              name: name,
              status: status,
              version: version,
              timestamp: timestamp || ::Time.now,
              seq: seq,
              provider: provider,
              model: model,
              input_tokens: input_tokens,
              output_tokens: output_tokens,
              conversation_id: conversation_id,
              task_id: task_id
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          def self.from_hash(hash)
            return nil if hash.nil?

            h = hash.transform_keys(&:to_sym)

            # Normalize role to symbol
            role_raw = h[:role]
            h[:role] = role_raw&.to_sym if role_raw

            # Parse content blocks if they're an array of hashes
            content = h[:content]
            if content.is_a?(Array)
              h[:content] = content.map do |block|
                block.is_a?(ContentBlock) ? block : ContentBlock.from_hash(block)
              end
            elsif content.is_a?(Hash)
              h[:content] = ContentBlock.from_hash(content)
            end

            # Parse tool calls if they're an array of hashes
            tool_calls = h[:tool_calls]
            if tool_calls.is_a?(Array)
              h[:tool_calls] = tool_calls.map do |tc|
                tc.is_a?(ToolCall) ? tc : ToolCall.from_hash(tc)
              end
            end

            build(**h)
          end

          # Wrap input: pass through if already a Message, parse if Hash.
          def self.wrap(input)
            return input if input.is_a?(Message)
            return from_hash(input) if input.is_a?(Hash)

            nil
          end

          # Extract plain text from content (String or ContentBlock array).
          def text
            case content
            when String then content
            when Array
              content.filter_map do |block|
                block.is_a?(ContentBlock) && block.text? ? block.text : nil
              end.join
            when ContentBlock then content.text if content.text?
            else
              content.to_s
            end
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            super.compact
          end

          # Minimal provider-facing hash (role + text content).
          def to_provider_hash
            { role: role.to_s, content: text }.compact
          end
        end

        Message::ROLES = %i[system user assistant tool].freeze
        # rubocop:enable Lint/ConstantDefinitionInBlock
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists, Metrics/PerceivedComplexity
