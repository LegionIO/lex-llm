# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::Chunk do
  let(:type_class) { described_class }
  let(:auto_generated_members) { [:timestamp] }
  let(:type_source) do
    {
      request_id: 'req_1',
      conversation_id: 'conv_1',
      exchange_id: 'exch_1',
      index: 3,
      type: 'text_delta',
      delta: 'hello',
      metadata: { origin: 'provider' }
    }
  end

  it_behaves_like 'a canonical type'

  describe 'G20d — produce side strict, consume side lenient' do
    it 'produces valid CHUNK_TYPES via the named factories' do
      expect(described_class.text_delta(delta: 'x', request_id: 'r').type).to eq(:text_delta)
      expect(described_class.thinking_delta(delta: 'x', request_id: 'r').type).to eq(:thinking_delta)
      expect(described_class.tool_call_delta(tool_call: { id: 'i' }, request_id: 'r').type).to eq(:tool_call_delta)
      expect(described_class.usage_chunk(usage: Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 1),
                                         request_id: 'r').type).to eq(:usage)
      expect(described_class.done(request_id: 'r').type).to eq(:done)
      expect(described_class.error_chunk(error: 'boom', request_id: 'r').type).to eq(:error)
    end

    it 'the generic produce path validates type against CHUNK_TYPES' do
      expect { described_class.build(type: :bogus, request_id: 'r') }
        .to raise_error(ArgumentError, /Invalid type: :bogus/)
      expect(described_class.build(type: 'usage', request_id: 'r').type).to eq(:usage)
    end

    it 'consume passes unknown types through unchanged (ignore-unknown on consume)' do
      chunk = described_class.from_hash(type: 'weird_custom_type', delta: 'x')
      expect(chunk.type).to eq(:weird_custom_type)
    end
  end

  describe 'O03a — no finish_reason alias' do
    it 'does not translate finish_reason (it folds into metadata)' do
      chunk = described_class.from_hash(type: 'done', stop_reason: nil, finish_reason: 'stop')
      expect(chunk.stop_reason).to be_nil
      expect(chunk.metadata).to eq(finish_reason: 'stop')
    end
  end

  describe 'nested member normalization (L2)' do
    it 'normalizes Hash usage and tool_call fragments' do
      chunk = described_class.from_hash(
        type: 'usage',
        usage: { input_tokens: 5 },
        tool_call: { id: 'i1', name: 'f', arguments: '{"a"', index: 0 }
      )
      expect(chunk.usage).to be_a(Legion::Extensions::Llm::Canonical::Usage)
      expect(chunk.usage.input_tokens).to eq(5)
      expect(chunk.tool_call).to eq(id: 'i1', name: 'f', arguments: '{"a"', index: 0)
    end

    it 'raises on wrong-class nested members' do
      expect { described_class.from_hash(type: 'usage', usage: 'nope') }
        .to raise_error(ArgumentError, /usage expected Hash, got String/)
      expect { described_class.build(tool_call: 42, type: :tool_call_delta, request_id: 'r') }
        .to raise_error(ArgumentError, /tool_call expected Hash \| .+ToolCall, got Integer/)
    end
  end

  describe 'T4 — signature and usage survive the wire' do
    it 'survives build → to_h → JSON → from_hash' do
      chunk = described_class.thinking_delta(delta: 'hmm', request_id: 'r', signature: 'sig-9')
      wire = Legion::JSON.load(Legion::JSON.dump(chunk.to_h))
      round_tripped = described_class.from_hash(wire)
      expect(round_tripped.signature).to eq('sig-9')
      expect(round_tripped.delta).to eq('hmm')
      expect(round_tripped.type).to eq(:thinking_delta)
    end
  end

  it 'auto-stamps timestamp when absent and exposes the predicates' do
    chunk = described_class.text_delta(delta: 'x', request_id: 'r')
    expect(chunk.timestamp).to be_a(Time)
    expect(chunk.text_delta?).to be(true)
    expect(chunk.content?).to be(true)
    expect(described_class.done(request_id: 'r').done?).to be(true)
    expect(described_class.error_chunk(error: 'e', request_id: 'r').metadata[:error]).to eq('e')
  end
end
