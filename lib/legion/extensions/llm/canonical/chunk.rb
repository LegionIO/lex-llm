# frozen_string_literal: true

# rubocop:disable Metrics/ParameterLists -- factory methods have many params
module Legion
  module Extensions
    module Llm
      module Canonical
        # Canonical streaming chunk with full lifecycle support.
        # Per R4: block_index/item_id/signature lifecycle, multi-tool-call deltas.
        # Per G20d (04 §11, stated law): strict on produce — the named factories
        # and the generic build validate type against CHUNK_TYPES; lenient on
        # consume — from_hash accepts any type symbol and passes it through. # -- required for Data.define block scope
        Chunk = ::Data.define(
          :request_id, :conversation_id, :exchange_id,
          :index, :type, :block_index,
          :item_id, :delta, :tool_call, :signature,
          :usage, :stop_reason, :metadata, :timestamp
        ) do
          # Generic produce path — the only way to construct an arbitrary-type
          # chunk; type is validated against CHUNK_TYPES (G20d).
          def self.build(
            type:, request_id: nil, conversation_id: nil, exchange_id: nil,
            index: nil, block_index: nil, item_id: nil,
            delta: nil, tool_call: nil, signature: nil,
            usage: nil, stop_reason: nil, metadata: {}, timestamp: nil
          )
            type_sym = type.is_a?(::String) ? type.to_sym : type
            Strict.enum!(type_sym, self::CHUNK_TYPES, self::BUILD_SITE, :type)
            new(
              request_id:, conversation_id:, exchange_id:,
              index:, type: type_sym, block_index:,
              item_id:, delta:,
              tool_call: normalize_tool_call!(tool_call, self::BUILD_SITE),
              signature:,
              usage: normalize_usage!(usage, self::BUILD_SITE),
              stop_reason: stop_reason&.to_sym,
              metadata: Strict.metadata!(metadata, self::BUILD_SITE),
              timestamp: timestamp || ::Time.now
            )
          end

          # Build a text delta chunk.
          def self.text_delta(delta:, request_id:, conversation_id: nil, exchange_id: nil,
                              index: 0, block_index: nil, item_id: nil,
                              stop_reason: nil, usage: nil)
            build(
              type: :text_delta, delta:, request_id:, conversation_id:, exchange_id:,
              index:, block_index:, item_id:, stop_reason:, usage:
            )
          end

          # Build a thinking delta chunk.
          def self.thinking_delta(delta:, request_id:, conversation_id: nil, exchange_id: nil,
                                  index: 0, block_index: nil, item_id: nil, signature: nil,
                                  stop_reason: nil, usage: nil)
            build(
              type: :thinking_delta, delta:, request_id:, conversation_id:, exchange_id:,
              index:, block_index:, item_id:, signature:, stop_reason:, usage:
            )
          end

          # Build a tool_call_delta chunk (supports multiple in-flight tool calls
          # via the fragment's id/index). tool_call is the delta fragment:
          # { id:, name:, arguments: <String fragment>, index:, signature: }.
          def self.tool_call_delta(tool_call:, request_id:, conversation_id: nil, exchange_id: nil,
                                   index: 0, block_index: nil, item_id: nil,
                                   stop_reason: nil, usage: nil)
            build(
              type: :tool_call_delta, tool_call:, request_id:, conversation_id:, exchange_id:,
              index:, block_index:, item_id:, stop_reason:, usage:
            )
          end

          # Build a usage chunk.
          def self.usage_chunk(usage:, request_id:, conversation_id: nil, exchange_id: nil)
            build(type: :usage, request_id:, conversation_id:, exchange_id:, usage:)
          end

          # Build a done chunk.
          def self.done(request_id:, usage: nil, stop_reason: nil, conversation_id: nil, exchange_id: nil)
            build(type: :done, request_id:, usage:, stop_reason:, conversation_id:, exchange_id:)
          end

          # Build an error chunk.
          def self.error_chunk(error:, request_id:, conversation_id: nil, exchange_id: nil, metadata: {})
            build(
              type: :error, request_id:, conversation_id:, exchange_id:,
              stop_reason: :error, metadata: metadata.merge(error:)
            )
          end

          def self.shape_symbol!(value, site, member)
            return nil if value.nil?
            return value.to_sym if value.is_a?(::String) || value.is_a?(::Symbol)

            raise ArgumentError, "#{site}: #{member} expected String or Symbol, got #{value.class}"
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          # Per G20d: ignore-unknown on consume — unknown chunk types pass through.
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            type_raw = hash.delete(:type)
            tool_call = normalize_tool_call!(hash.delete(:tool_call), self::FROM_HASH_SITE)
            usage = normalize_usage!(hash.delete(:usage), self::FROM_HASH_SITE)
            stop_reason_raw = hash.delete(:stop_reason)
            timestamp = hash.delete(:timestamp)
            # Remaining keys are all members; pass through with consume defaults.
            new(
              request_id: hash[:request_id],
              conversation_id: hash[:conversation_id],
              exchange_id: hash[:exchange_id],
              index: hash[:index],
              type: type_raw&.to_sym,
              block_index: hash[:block_index],
              item_id: hash[:item_id],
              delta: hash[:delta],
              tool_call:,
              signature: hash[:signature],
              usage:,
              stop_reason: stop_reason_raw&.to_sym,
              metadata:,
              timestamp: timestamp || ::Time.now
            )
          end

          # tool_call member: the delta fragment (Hash) or a full ToolCall; nil allowed.
          def self.normalize_tool_call!(tool_call, site)
            return nil if tool_call.nil?
            return tool_call if tool_call.is_a?(::Hash) || tool_call.is_a?(ToolCall)

            Strict.expect_type!(tool_call, [::Hash, ToolCall], site, :tool_call)
          end

          def self.normalize_usage!(usage, site)
            return nil if usage.nil?
            return usage if usage.is_a?(Usage)

            Strict.expect_type!(usage, [::Hash], site, :usage)
            Usage.from_hash(usage)
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

          # H1: the single strict constructor. Member shapes are validated
          # (type/stop_reason as String|Symbol, tool_call/usage through the
          # normalizers, metadata as a Hash). Per G20d the TYPE is only
          # shape-checked here — the produce-side enum pin stays in build,
          # and from_hash (consume) passes unknown types through.
          Strict.install_strict_new!(self) do |values, site|
            values[:type] = shape_symbol!(values[:type], site, :type)
            values[:stop_reason] = shape_symbol!(values[:stop_reason], site, :stop_reason)
            values[:tool_call] = normalize_tool_call!(values[:tool_call], site)
            values[:usage] = normalize_usage!(values[:usage], site)
            values[:metadata] = Strict.metadata!(values[:metadata], site)
            values
          end
        end

        Chunk::CHUNK_TYPES = %i[text_delta thinking_delta tool_call_delta usage done error].freeze
        Chunk::BUILD_SITE = 'Canonical::Chunk.build'
        Chunk::FROM_HASH_SITE = 'Canonical::Chunk.from_hash'
        Chunk::NEW_SITE = 'Canonical::Chunk.new'
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
