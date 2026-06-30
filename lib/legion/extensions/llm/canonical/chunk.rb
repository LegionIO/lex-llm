# frozen_string_literal: true

# rubocop:disable Metrics/ParameterLists -- factory methods have many params
module Legion
  module Extensions
    module Llm
      module Canonical
        # Canonical streaming chunk with full lifecycle support.
        # Per R4: block_index/item_id/signature lifecycle, multi-tool-call deltas.
        # Per G20d: strict on produce, ignore-unknown on consume.
        Chunk = ::Data.define(
          :request_id, :conversation_id, :exchange_id,
          :index, :type, :block_index,
          :item_id, :delta, :tool_call, :signature,
          :usage, :stop_reason, :metadata, :timestamp
        ) do
          # Build a text delta chunk.
          def self.text_delta(delta:, request_id:, conversation_id: nil, exchange_id: nil,
                              index: 0, block_index: nil, item_id: nil)
            new(
              type: :text_delta, delta: delta, index: index,
              request_id: request_id, conversation_id: conversation_id,
              exchange_id: exchange_id, block_index: block_index,
              item_id: item_id, tool_call: nil, signature: nil,
              usage: nil, stop_reason: nil, metadata: {},
              timestamp: ::Time.now
            )
          end

          # Build a thinking delta chunk.
          def self.thinking_delta(delta:, request_id:, conversation_id: nil, exchange_id: nil,
                                  index: 0, block_index: nil, item_id: nil, signature: nil)
            new(
              type: :thinking_delta, delta: delta, index: index,
              request_id: request_id, conversation_id: conversation_id,
              exchange_id: exchange_id, block_index: block_index,
              item_id: item_id, tool_call: nil, signature: signature,
              usage: nil, stop_reason: nil, metadata: {},
              timestamp: ::Time.now
            )
          end

          # Build a tool_call_delta chunk (supports multiple in-flight tool calls via tool_call.id).
          def self.tool_call_delta(tool_call:, request_id:, conversation_id: nil, exchange_id: nil,
                                   index: 0, block_index: nil, item_id: nil)
            new(
              type: :tool_call_delta, index: index,
              request_id: request_id, conversation_id: conversation_id,
              exchange_id: exchange_id, block_index: block_index,
              item_id: item_id, delta: nil, tool_call: tool_call, signature: nil,
              usage: nil, stop_reason: nil, metadata: {},
              timestamp: ::Time.now
            )
          end

          # Build a usage chunk.
          def self.usage_chunk(usage:, request_id:, conversation_id: nil, exchange_id: nil)
            new(
              type: :usage, request_id: request_id,
              conversation_id: conversation_id, exchange_id: exchange_id,
              index: nil, block_index: nil, item_id: nil,
              delta: nil, tool_call: nil, signature: nil,
              usage: usage, stop_reason: nil, metadata: {},
              timestamp: ::Time.now
            )
          end

          # Build a done chunk.
          def self.done(request_id:, usage: nil, stop_reason: nil, conversation_id: nil, exchange_id: nil)
            new(
              type: :done, request_id: request_id,
              conversation_id: conversation_id, exchange_id: exchange_id,
              index: nil, block_index: nil, item_id: nil,
              delta: nil, tool_call: nil, signature: nil,
              usage: usage, stop_reason: stop_reason, metadata: {},
              timestamp: ::Time.now
            )
          end

          # Build an error chunk.
          def self.error_chunk(error:, request_id:, conversation_id: nil, exchange_id: nil, metadata: nil)
            new(
              type: :error, request_id: request_id,
              conversation_id: conversation_id, exchange_id: exchange_id,
              index: nil, block_index: nil, item_id: nil,
              delta: nil, tool_call: nil, signature: nil,
              usage: nil, stop_reason: :error,
              metadata: (metadata || {}).merge(error: error),
              timestamp: ::Time.now
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          # Per G20d: ignore-unknown on consume — unknown chunk types are passed through.
          def self.from_hash(source)
            return nil if source.nil?

            h = source.transform_keys(&:to_sym)

            # Normalize type
            type_raw = h.delete(:type)
            type_sym = type_raw&.to_sym if type_raw

            # Normalize nested objects
            tool_call_raw = h.delete(:tool_call)
            h[:tool_call] = if tool_call_raw.is_a?(ToolCall)
                              tool_call_raw
                            elsif tool_call_raw.is_a?(Hash)
                              ToolCall.from_hash(tool_call_raw)
                            end

            usage_raw = h.delete(:usage)
            h[:usage] = if usage_raw.is_a?(Usage)
                          usage_raw
                        elsif usage_raw.is_a?(Hash)
                          Usage.from_hash(usage_raw)
                        end

            # Normalize stop_reason
            stop_reason_raw = h.delete(:stop_reason) || h.delete(:finish_reason)
            h[:stop_reason] = stop_reason_raw&.to_sym if stop_reason_raw

            # Ensure metadata is a Hash
            h[:metadata] = h[:metadata] || {}

            # Provide defaults for missing fields
            new(
              request_id: h[:request_id],
              conversation_id: h[:conversation_id],
              exchange_id: h[:exchange_id],
              index: h[:index],
              type: type_sym,
              block_index: h[:block_index],
              item_id: h[:item_id],
              delta: h[:delta],
              tool_call: h[:tool_call],
              signature: h[:signature],
              usage: h[:usage],
              stop_reason: h[:stop_reason],
              metadata: h[:metadata],
              timestamp: h[:timestamp] || ::Time.now
            )
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            {
              request_id: request_id,
              conversation_id: conversation_id,
              exchange_id: exchange_id,
              index: index,
              type: type,
              block_index: block_index,
              item_id: item_id,
              delta: delta,
              tool_call: tool_call&.to_h,
              signature: signature,
              usage: usage&.to_h,
              stop_reason: stop_reason,
              metadata: metadata,
              timestamp: timestamp
            }.compact
          end

          # MultiJson/Oj/::JSON callback — prevents Data.define #inspect leak into JSON.
          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
          end

          # Type predicate helpers.
          def text_delta? = type == :text_delta
          def thinking_delta? = type == :thinking_delta
          def tool_call_delta? = type == :tool_call_delta
          def usage? = type == :usage
          def done? = type == :done
          def error? = type == :error

          # Whether this chunk carries content (text or thinking).
          def content?
            %i[text_delta thinking_delta].include?(type)
          end
        end

        Chunk::CHUNK_TYPES = %i[text_delta thinking_delta tool_call_delta usage done error].freeze
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
