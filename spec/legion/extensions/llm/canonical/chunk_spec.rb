# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::Chunk do
  describe '.text_delta' do
    it 'creates a text delta chunk' do
      chunk = described_class.text_delta(delta: 'hello', request_id: 'req-1')

      expect(chunk.type).to eq(:text_delta)
      expect(chunk.delta).to eq('hello')
      expect(chunk.request_id).to eq('req-1')
      expect(chunk.index).to eq(0)
      expect(chunk.timestamp).to be_a(Time)
    end

    it 'accepts block_index and item_id' do
      chunk = described_class.text_delta(
        delta: 'hello',
        request_id: 'req-1',
        block_index: 0,
        item_id: 'item-1'
      )

      expect(chunk.block_index).to eq(0)
      expect(chunk.item_id).to eq('item-1')
    end
  end

  describe '.thinking_delta' do
    it 'creates a thinking delta chunk' do
      chunk = described_class.thinking_delta(
        delta: 'reasoning',
        request_id: 'req-1',
        signature: 'sig-partial'
      )

      expect(chunk.type).to eq(:thinking_delta)
      expect(chunk.delta).to eq('reasoning')
      expect(chunk.signature).to eq('sig-partial')
    end
  end

  describe '.tool_call_delta' do
    it 'creates a tool call delta chunk' do
      tool_call = Legion::Extensions::Llm::Canonical::ToolCall.build(name: 'search')
      chunk = described_class.tool_call_delta(tool_call: tool_call, request_id: 'req-1')

      expect(chunk.type).to eq(:tool_call_delta)
      expect(chunk.tool_call).to eq(tool_call)
    end
  end

  describe '.usage_chunk' do
    it 'creates a usage chunk' do
      usage = Legion::Extensions::Llm::Canonical::Usage.new(
        input_tokens: 100, output_tokens: 50,
        cache_read_tokens: nil, cache_write_tokens: nil,
        thinking_tokens: nil, units: {}
      )
      chunk = described_class.usage_chunk(usage: usage, request_id: 'req-1')

      expect(chunk.type).to eq(:usage)
      expect(chunk.usage).to eq(usage)
    end
  end

  describe '.done' do
    it 'creates a done chunk' do
      chunk = described_class.done(request_id: 'req-1', stop_reason: :end_turn)

      expect(chunk.type).to eq(:done)
      expect(chunk.stop_reason).to eq(:end_turn)
    end

    it 'includes usage when provided' do
      usage = Legion::Extensions::Llm::Canonical::Usage.new(
        input_tokens: 100, output_tokens: 50,
        cache_read_tokens: nil, cache_write_tokens: nil,
        thinking_tokens: nil, units: {}
      )
      chunk = described_class.done(request_id: 'req-1', usage: usage, stop_reason: :end_turn)

      expect(chunk.usage).to eq(usage)
    end
  end

  describe '.error_chunk' do
    it 'creates an error chunk' do
      chunk = described_class.error_chunk(error: 'timeout', request_id: 'req-1')

      expect(chunk.type).to eq(:error)
      expect(chunk.stop_reason).to eq(:error)
      expect(chunk.metadata[:error]).to eq('timeout')
    end

    it 'merges additional metadata' do
      chunk = described_class.error_chunk(
        error: 'timeout',
        request_id: 'req-1',
        metadata: { provider: 'anthropic' }
      )

      expect(chunk.metadata[:error]).to eq('timeout')
      expect(chunk.metadata[:provider]).to eq('anthropic')
    end
  end

  describe '.from_hash' do
    it 'parses from hash with symbol keys' do
      chunk = described_class.from_hash(
        type: :text_delta,
        delta: 'hello',
        request_id: 'req-1'
      )

      expect(chunk.type).to eq(:text_delta)
      expect(chunk.delta).to eq('hello')
      expect(chunk.request_id).to eq('req-1')
    end

    it 'normalizes type string to symbol' do
      chunk = described_class.from_hash(type: 'text_delta', delta: 'hello', request_id: 'req-1')

      expect(chunk.type).to eq(:text_delta)
    end

    it 'parses nested tool_call' do
      chunk = described_class.from_hash(
        type: :tool_call_delta,
        request_id: 'req-1',
        tool_call: { name: 'search', arguments: { query: 'test' } }
      )

      expect(chunk.tool_call).to be_a(Legion::Extensions::Llm::Canonical::ToolCall)
      expect(chunk.tool_call.name).to eq('search')
    end

    it 'parses nested usage' do
      chunk = described_class.from_hash(
        type: :usage,
        request_id: 'req-1',
        usage: { input_tokens: 100, output_tokens: 50 }
      )

      expect(chunk.usage).to be_a(Legion::Extensions::Llm::Canonical::Usage)
    end

    it 'normalizes stop_reason' do
      chunk = described_class.from_hash(
        type: :done,
        request_id: 'req-1',
        stop_reason: 'end_turn'
      )

      expect(chunk.stop_reason).to eq(:end_turn)
    end

    it 'accepts finish_reason as alias' do
      chunk = described_class.from_hash(
        type: :done,
        request_id: 'req-1',
        finish_reason: 'tool_use'
      )

      expect(chunk.stop_reason).to eq(:tool_use)
    end

    it 'returns nil for nil source' do
      expect(described_class.from_hash(nil)).to be_nil
    end

    it 'handles string keys' do
      chunk = described_class.from_hash(
        'type' => 'text_delta',
        'delta' => 'hello',
        'request_id' => 'req-1'
      )

      expect(chunk.type).to eq(:text_delta)
      expect(chunk.delta).to eq('hello')
    end
  end

  describe '#to_h' do
    it 'serializes to compact hash' do
      chunk = described_class.text_delta(delta: 'hello', request_id: 'req-1')
      hash = chunk.to_h

      expect(hash).to include(type: :text_delta, delta: 'hello', request_id: 'req-1')
    end

    it 'serializes nested objects' do
      tool_call = Legion::Extensions::Llm::Canonical::ToolCall.build(name: 'search')
      chunk = described_class.tool_call_delta(tool_call: tool_call, request_id: 'req-1')
      hash = chunk.to_h

      expect(hash[:tool_call]).to be_a(Hash)
      expect(hash[:tool_call][:name]).to eq('search')
    end
  end

  describe 'type predicates' do
    it 'identifies text_delta chunks' do
      chunk = described_class.text_delta(delta: 'hello', request_id: 'req-1')
      expect(chunk.text_delta?).to be true
      expect(chunk.content?).to be true
    end

    it 'identifies thinking_delta chunks' do
      chunk = described_class.thinking_delta(delta: 'reasoning', request_id: 'req-1')
      expect(chunk.thinking_delta?).to be true
      expect(chunk.content?).to be true
    end

    it 'identifies tool_call_delta chunks' do
      tc = Legion::Extensions::Llm::Canonical::ToolCall.build(name: 'search')
      chunk = described_class.tool_call_delta(tool_call: tc, request_id: 'req-1')
      expect(chunk.tool_call_delta?).to be true
      expect(chunk.content?).to be false
    end

    it 'identifies usage chunks' do
      usage = Legion::Extensions::Llm::Canonical::Usage.new(
        input_tokens: 100, output_tokens: 50,
        cache_read_tokens: nil, cache_write_tokens: nil,
        thinking_tokens: nil, units: {}
      )
      chunk = described_class.usage_chunk(usage: usage, request_id: 'req-1')
      expect(chunk.usage?).to be true
    end

    it 'identifies done chunks' do
      chunk = described_class.done(request_id: 'req-1')
      expect(chunk.done?).to be true
    end

    it 'identifies error chunks' do
      chunk = described_class.error_chunk(error: 'timeout', request_id: 'req-1')
      expect(chunk.error?).to be true
    end
  end

  describe 'CHUNK_TYPES' do
    it 'includes all expected chunk types' do
      expect(described_class::CHUNK_TYPES).to eq(
        %i[text_delta thinking_delta tool_call_delta usage done error]
      )
    end
  end

  describe 'round-trip' do
    it 'preserves text_delta through from_hash/to_h' do
      original = {
        type: 'text_delta',
        delta: 'hello',
        request_id: 'req-1',
        block_index: 0,
        item_id: 'item-1'
      }
      chunk = described_class.from_hash(original)
      serialized = chunk.to_h

      expect(serialized[:type]).to eq(:text_delta)
      expect(serialized[:delta]).to eq('hello')
      expect(serialized[:block_index]).to eq(0)
      expect(serialized[:item_id]).to eq('item-1')
    end

    it 'preserves done chunk through from_hash/to_h' do
      original = {
        type: 'done',
        request_id: 'req-1',
        stop_reason: 'end_turn',
        usage: { input_tokens: 100, output_tokens: 50 }
      }
      chunk = described_class.from_hash(original)
      serialized = chunk.to_h

      expect(serialized[:type]).to eq(:done)
      expect(serialized[:stop_reason]).to eq(:end_turn)
      expect(serialized[:usage]).to include(input_tokens: 100, output_tokens: 50)
    end
  end
end
