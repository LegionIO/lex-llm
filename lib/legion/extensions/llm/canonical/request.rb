# frozen_string_literal: true

require 'securerandom'

# rubocop:disable Metrics/ParameterLists -- factory methods have many params
module Legion
  module Extensions
    module Llm
      module Canonical
        # Canonical request shape — the single contract between client translators
        # and the inference executor. Per R3 and G18.
        Request = ::Data.define(
          :id, :messages, :system, :tools, :tool_choice,
          :params, :thinking, :stream,
          :conversation_id, :caller, :routing, :metadata
        ) do
          # Build from keyword args (primary constructor).
          def self.build(
            id: nil, messages: nil, system: nil, tools: nil, tool_choice: nil,
            params: nil, thinking: nil, stream: false,
            conversation_id: nil, caller: nil, routing: nil, metadata: nil
          )
            # Normalize messages to Canonical::Message array
            msg_array = Array(messages).filter_map do |msg|
              msg.is_a?(Message) ? msg : Message.from_hash(msg)
            end

            # Normalize tools to Hash<name, ToolDefinition>
            tool_hash = normalize_tools(tools)

            # Normalize params
            params_obj = case params
                         when Params then params
                         when Hash then Params.from_hash(params)
                         end

            # Normalize thinking config
            thinking_obj = case thinking
                           when Thinking::Config then thinking
                           when Hash then Thinking::Config.new(**thinking.transform_keys(&:to_sym))
                           end

            new(
              id: id || "req_#{SecureRandom.hex(12)}",
              messages: msg_array,
              system: system,
              tools: tool_hash,
              tool_choice: tool_choice.is_a?(String) ? tool_choice.to_sym : tool_choice,
              params: params_obj,
              thinking: thinking_obj,
              stream: stream,
              conversation_id: conversation_id,
              caller: caller,
              routing: routing || {},
              metadata: metadata || {}
            )
          end

          # Build from a Hash (raw client request or deserialized wire payload).
          def self.from_hash(source)
            return nil if source.nil?

            h = source.transform_keys(&:to_sym)

            # Extract metadata from unknown keys
            metadata = h[:metadata] || {}
            known_keys = %i[id messages system tools tool_choice params thinking
                            stream conversation_id caller routing metadata]
            (h.keys - known_keys).each do |key|
              metadata[key] = h.delete(key)
            end
            h[:metadata] = metadata

            build(**h)
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            {
              id: id,
              messages: messages&.map { |m| m.is_a?(Message) ? m.to_h : m },
              system: system,
              tools: tools&.transform_values { |t| t.is_a?(ToolDefinition) ? t.to_h : t },
              tool_choice: tool_choice,
              params: params&.to_h,
              thinking: thinking&.to_h,
              stream: stream,
              conversation_id: conversation_id,
              caller: caller,
              routing: routing,
              metadata: metadata
            }.compact
          end

          # MultiJson/Oj/::JSON callback — prevents Data.define #inspect leak into JSON.
          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
          end

          def self.normalize_tools(tools)
            return {} if tools.nil? || tools.empty?

            case tools
            when Hash
              tools.transform_values do |tool|
                tool.is_a?(ToolDefinition) ? tool : ToolDefinition.from_hash(tool)
              end
            when Array
              tools.each_with_object({}) do |tool, hash|
                td = tool.is_a?(ToolDefinition) ? tool : ToolDefinition.from_hash(tool)
                hash[td.name] = td
              end
            else
              {}
            end
          end
        end
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
