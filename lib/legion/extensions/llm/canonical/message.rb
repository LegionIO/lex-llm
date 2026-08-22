# frozen_string_literal: true

require 'securerandom'

# rubocop:disable Metrics/ParameterLists -- factory methods have many params
module Legion
  module Extensions
    module Llm
      # -- required for Data.define block scope
      module Canonical
        # Canonical message in a conversation.
        # Ports field vocabulary from Legion::LLM::Types::Message.
        # Unknown keys fold into the metadata member (04 L5) — never dropped.
        # :cache_control (prompt-cache breakpoints) IS a member and survives
        # build/to_h/JSON round-trips, including the fleet wire.
        Message = ::Data.define(
          :id, :parent_id, :role, :content, :tool_calls, :tool_call_id,
          :name, :status, :version, :timestamp, :seq,
          :provider, :model, :input_tokens, :output_tokens,
          :conversation_id, :task_id, :cache_control, :metadata
        ) do
          # Build from keyword args (primary constructor).
          def self.build(
            id: nil, parent_id: nil, role: :user, content: nil, tool_calls: nil,
            tool_call_id: nil, name: nil, status: :created, version: 1,
            timestamp: nil, seq: nil, provider: nil, model: nil,
            input_tokens: nil, output_tokens: nil, conversation_id: nil, task_id: nil,
            cache_control: nil, metadata: {}
          )
            new(
              id: id || "msg_#{SecureRandom.hex(12)}",
              parent_id: parent_id,
              role: normalize_role!(role, self::BUILD_SITE),
              content: normalize_content!(content, self::BUILD_SITE),
              tool_calls: normalize_tool_calls!(tool_calls, self::BUILD_SITE),
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
              task_id: task_id,
              cache_control: cache_control.nil? ? nil : Strict.expect_type!(cache_control, [::Hash], self::BUILD_SITE, :cache_control),
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

          # L6: role validated at construction, in both factories.
          def self.normalize_role!(role, site)
            role_sym = role.is_a?(::String) ? role.to_sym : role
            Strict.enum!(role_sym, self::ROLES, site, :role)
          end

          # L2: one content normalizer shared by build and from_hash.
          # String | ContentBlock | Array<ContentBlock> | nil — anything else raises.
          def self.normalize_content!(content, site)
            return nil if content.nil?
            return content if content.is_a?(::String) || content.is_a?(ContentBlock)
            raise ArgumentError, "#{site}: content expected String | ContentBlock | Array, got #{content.class}" unless content.is_a?(::Array)

            content.map { |block| block.is_a?(ContentBlock) ? block : ContentBlock.from_hash(block) }
          end

          # L2: one tool-call normalizer shared by build and from_hash.
          # Array<ToolCall> | nil (Array is canonical; the legacy Hash shape is gone).
          def self.normalize_tool_calls!(tool_calls, site)
            return nil if tool_calls.nil?

            Strict.expect_type!(tool_calls, [::Array], site, :tool_calls)
            tool_calls.map { |tc| tc.is_a?(ToolCall) ? tc : ToolCall.from_hash(tc) }
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

          # MultiJson/Oj/::JSON callback — prevents Data.define #inspect leak into JSON.
          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
          end

          # Human-readable string — prevents #inspect leaking into user-facing output.
          def to_s
            text
          end

          # H1: the single strict constructor — .new runs the same member
          # contract as the factories (normalize or raise); the factories
          # fill their defaults and delegate here. Missing members follow the
          # nil contract of each member.
          Strict.install_strict_new!(self) do |values, site|
            values[:role] = normalize_role!(values[:role], site)
            values[:content] = normalize_content!(values[:content], site)
            values[:tool_calls] = normalize_tool_calls!(values[:tool_calls], site)
            values[:cache_control] = values[:cache_control].nil? ? nil : Strict.expect_type!(values[:cache_control], [::Hash], site, :cache_control)
            values[:metadata] = Strict.metadata!(values[:metadata], site)
            values
          end
        end

        Message::ROLES = %i[system user assistant tool].freeze
        Message::BUILD_SITE = 'Canonical::Message.build'
        Message::FROM_HASH_SITE = 'Canonical::Message.from_hash'
        Message::NEW_SITE = 'Canonical::Message.new'
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
