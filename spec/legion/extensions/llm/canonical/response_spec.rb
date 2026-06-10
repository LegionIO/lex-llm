# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::Response do
  describe '.from_hash' do
    it 'returns a Response instance with canonical fields' do
      resp = described_class.from_hash(
        text: 'Hello world',
        stop_reason: 'end_turn',
        model: 'claude-sonnet-4-6'
      )

      expect(resp).to be_a(described_class)
      expect(resp.text).to eq('Hello world')
      expect(resp.stop_reason).to eq(:end_turn)
      expect(resp.model).to eq('claude-sonnet-4-6')
      expect(resp.tool_calls).to eq([])
    end

    it 'normalizes stop_reason to symbol' do
      resp = described_class.from_hash(stop_reason: 'tool_use')

      expect(resp.stop_reason).to eq(:tool_use)
    end

    it 'parses thinking from nested hash' do
      resp = described_class.from_hash(
        text: 'answer',
        thinking: { content: 'reasoning', signature: 'sig-1' }
      )

      expect(resp.thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking)
      expect(resp.thinking.content).to eq('reasoning')
    end

    it 'parses usage from nested hash' do
      resp = described_class.from_hash(
        text: 'answer',
        usage: { input_tokens: 100, output_tokens: 50 }
      )

      expect(resp.usage).to be_a(Legion::Extensions::Llm::Canonical::Usage)
      expect(resp.usage.input_tokens).to eq(100)
    end

    it 'parses tool_calls from array of hashes' do
      resp = described_class.from_hash(
        text: '',
        tool_calls: [{ name: 'search', arguments: { query: 'test' } }]
      )

      expect(resp.tool_calls).to be_an(Array)
      expect(resp.tool_calls.first).to be_a(Legion::Extensions::Llm::Canonical::ToolCall)
    end

    it 'accepts finish_reason as alias for stop_reason' do
      resp = described_class.from_hash(finish_reason: 'max_tokens')

      expect(resp.stop_reason).to eq(:max_tokens)
    end

    it 'accepts content as alias for text' do
      resp = described_class.from_hash(content: 'Hello world')

      expect(resp.text).to eq('Hello world')
    end

    it 'moves unknown keys to metadata' do
      resp = described_class.from_hash(
        text: 'answer',
        cache_creation_input_tokens: 25,
        custom_field: 'value'
      )

      expect(resp.metadata[:cache_creation_input_tokens]).to eq(25)
      expect(resp.metadata[:custom_field]).to eq('value')
    end

    it 'merges unknown keys with existing metadata' do
      resp = described_class.from_hash(
        text: 'answer',
        metadata: { existing: 'data' },
        custom_field: 'value'
      )

      expect(resp.metadata[:existing]).to eq('data')
      expect(resp.metadata[:custom_field]).to eq('value')
    end

    it 'rejects invalid stop_reasons' do
      expect do
        described_class.from_hash(stop_reason: 'invalid_reason')
      end.to raise_error(ArgumentError, /Invalid stop_reason/)
    end

    it 'returns nil for nil source' do
      expect(described_class.from_hash(nil)).to be_nil
    end

    it 'handles string keys' do
      resp = described_class.from_hash(
        'text' => 'Hello',
        'stop_reason' => 'end_turn',
        'model' => 'claude-sonnet-4-6'
      )

      expect(resp.text).to eq('Hello')
      expect(resp.stop_reason).to eq(:end_turn)
    end
  end

  describe '.build' do
    it 'creates a response with defaults' do
      resp = described_class.build

      expect(resp.text).to eq('')
      expect(resp.tool_calls).to eq([])
      expect(resp.routing).to eq({})
      expect(resp.metadata).to eq({})
    end

    it 'creates a response with all fields' do
      thinking = Legion::Extensions::Llm::Canonical::Thinking.new(content: 'reasoning', signature: 'sig')
      usage = Legion::Extensions::Llm::Canonical::Usage.new(
        input_tokens: 100, output_tokens: 50,
        cache_read_tokens: nil, cache_write_tokens: nil,
        thinking_tokens: nil, units: {}
      )
      resp = described_class.build(
        text: 'answer',
        thinking: thinking,
        tool_calls: [],
        usage: usage,
        stop_reason: :end_turn,
        model: 'claude-sonnet-4-6'
      )

      expect(resp.text).to eq('answer')
      expect(resp.thinking).to eq(thinking)
      expect(resp.usage).to eq(usage)
      expect(resp.stop_reason).to eq(:end_turn)
      expect(resp.model).to eq('claude-sonnet-4-6')
    end

    it 'rejects invalid stop_reasons' do
      expect do
        described_class.build(stop_reason: :invalid_reason)
      end.to raise_error(ArgumentError, /Invalid stop_reason/)
    end
  end

  describe '#to_h' do
    it 'serializes to compact hash' do
      resp = described_class.build(text: 'answer', stop_reason: :end_turn, model: 'claude-sonnet-4-6')
      hash = resp.to_h

      expect(hash).to eq(
        text: 'answer',
        stop_reason: :end_turn,
        model: 'claude-sonnet-4-6'
      )
    end

    it 'serializes nested objects' do
      thinking = Legion::Extensions::Llm::Canonical::Thinking.new(content: 'reasoning', signature: 'sig')
      usage = Legion::Extensions::Llm::Canonical::Usage.new(
        input_tokens: 100, output_tokens: 50,
        cache_read_tokens: nil, cache_write_tokens: nil,
        thinking_tokens: nil, units: {}
      )
      resp = described_class.build(text: 'answer', thinking: thinking, usage: usage)
      hash = resp.to_h

      expect(hash[:thinking]).to eq(content: 'reasoning', signature: 'sig')
      expect(hash[:usage]).to include(input_tokens: 100, output_tokens: 50)
    end
  end

  describe 'predicates' do
    it 'identifies tool call responses' do
      resp = described_class.build(
        text: '',
        tool_calls: [Legion::Extensions::Llm::Canonical::ToolCall.build(name: 'search')]
      )

      expect(resp.tool_call?).to be true
    end

    it 'returns false for empty tool calls' do
      resp = described_class.build(text: 'answer', tool_calls: [])

      expect(resp.tool_call?).to be false
    end

    it 'identifies error responses' do
      resp = described_class.build(stop_reason: :error)

      expect(resp.error?).to be true
    end

    it 'returns false for non-error responses' do
      resp = described_class.build(stop_reason: :end_turn)

      expect(resp.error?).to be false
    end
  end

  describe 'STOP_REASONS' do
    it 'includes all expected stop reasons' do
      expect(described_class::STOP_REASONS).to eq(
        %i[end_turn tool_use max_tokens stop_sequence content_filter error]
      )
    end
  end

  describe 'round-trip' do
    it 'preserves values through from_hash/to_h' do
      original = {
        text: 'Hello world',
        stop_reason: 'end_turn',
        model: 'claude-sonnet-4-6',
        usage: { input_tokens: 100, output_tokens: 50 }
      }
      resp = described_class.from_hash(original)
      serialized = resp.to_h

      expect(serialized[:text]).to eq('Hello world')
      expect(serialized[:stop_reason]).to eq(:end_turn)
      expect(serialized[:model]).to eq('claude-sonnet-4-6')
      expect(serialized[:usage]).to include(input_tokens: 100, output_tokens: 50)
    end
  end
end
