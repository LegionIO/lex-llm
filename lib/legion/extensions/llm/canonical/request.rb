# frozen_string_literal: true

require 'securerandom'

# rubocop:disable Metrics/ParameterLists -- factory methods have many params
module Legion
  module Extensions
    module Llm
      module Canonical
        # Canonical request shape — the single contract between client translators
        # and the inference executor. Per R3 and G18. # -- required for Data.define block scope
        Request = ::Data.define(
          :id, :messages, :system, :tools, :tool_choice,
          :params, :thinking, :stream,
          :conversation_id, :caller, :routing, :metadata
        ) do
          # Build from keyword args (primary constructor).
          def self.build(
            id: nil, messages: nil, system: nil, tools: nil, tool_choice: nil,
            params: nil, thinking: nil, stream: false,
            conversation_id: nil, caller: nil, routing: nil, metadata: {}
          )
            new(
              id: id || "req_#{SecureRandom.hex(12)}",
              messages: normalize_messages!(messages, self::BUILD_SITE),
              system: system,
              tools: normalize_tools(tools, self::BUILD_SITE),
              tool_choice: tool_choice.is_a?(::String) ? tool_choice.to_sym : tool_choice,
              params: normalize_params!(params, self::BUILD_SITE),
              thinking: normalize_thinking!(thinking, self::BUILD_SITE),
              stream: stream,
              conversation_id: conversation_id,
              caller: caller,
              routing: routing || {},
              metadata: Strict.metadata!(metadata, self::BUILD_SITE)
            )
          end

          # Build from a Hash (raw client request or deserialized wire payload).
          # Unknown keys fold into metadata — the model for 04 L5.
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(**hash, metadata:)
          end

          # 04 §9: strict message map — each element must be a Message (pass) or a
          # Hash (normalize); anything else raises. No silent drops (F2 fix).
          def self.normalize_messages!(messages, site)
            return [] if messages.nil?

            Strict.expect_type!(messages, [::Array], site, :messages)
            messages.map { |msg| msg.is_a?(Message) ? msg : Message.from_hash(msg) }
          end

          # L2: the single tools normalizer, shared by build and from_hash.
          # Hash<name, ToolDefinition> or Array<ToolDefinition|Hash>; anything else raises.
          def self.normalize_tools(tools, site)
            return {} if tools.nil? || tools.empty?

            case tools
            when Hash
              tools.transform_values { |tool| tool.is_a?(ToolDefinition) ? tool : ToolDefinition.from_hash(tool) }
            when Array
              tools.each_with_object({}) do |tool, hash|
                td = tool.is_a?(ToolDefinition) ? tool : ToolDefinition.from_hash(tool)
                hash[td.name] = td
              end
            else
              Strict.expect_type!(tools, [::Hash, ::Array], site, :tools)
            end
          end

          def self.normalize_params!(params, site)
            return nil if params.nil?
            return params if params.is_a?(Params)

            Strict.expect_type!(params, [::Hash], site, :params)
            Params.from_hash(params)
          end

          def self.normalize_thinking!(thinking, site)
            return nil if thinking.nil?
            return thinking if thinking.is_a?(Thinking::Config)

            Strict.expect_type!(thinking, [::Hash], site, :thinking)
            Thinking::Config.from_hash(thinking)
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
        end

        Request::BUILD_SITE = 'Canonical::Request.build'
        Request::FROM_HASH_SITE = 'Canonical::Request.from_hash'
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
