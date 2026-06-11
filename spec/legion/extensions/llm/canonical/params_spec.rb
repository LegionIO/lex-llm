# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::Params do
  describe '.from_hash' do
    it 'returns a Params instance with canonical fields' do
      params = described_class.from_hash(max_tokens: 4096, temperature: 0.7)

      expect(params).to be_a(described_class)
      expect(params.max_tokens).to eq(4096)
      expect(params.temperature).to eq(0.7)
      expect(params.top_p).to be_nil
    end

    it 'normalizes max_output_tokens to max_tokens' do
      params = described_class.from_hash(max_output_tokens: 2048)

      expect(params.max_tokens).to eq(2048)
    end

    it 'normalizes num_predict to max_tokens' do
      params = described_class.from_hash(num_predict: 1024)

      expect(params.max_tokens).to eq(1024)
    end

    it 'normalizes budget_tokens to max_thinking_tokens' do
      params = described_class.from_hash(budget_tokens: 5000)

      expect(params.max_thinking_tokens).to eq(5000)
    end

    it 'normalizes thinking_budget to max_thinking_tokens' do
      params = described_class.from_hash(thinking_budget: 8000)

      expect(params.max_thinking_tokens).to eq(8000)
    end

    it 'normalizes stop to stop_sequences' do
      params = described_class.from_hash(stop: ['\n', 'END'])

      expect(params.stop_sequences).to eq(['\n', 'END'])
    end

    it 'handles string keys' do
      params = described_class.from_hash('max_tokens' => '4096', 'temperature' => '0.5')

      expect(params.max_tokens).to eq('4096')
      expect(params.temperature).to eq('0.5')
    end

    it 'returns nil for nil source' do
      expect(described_class.from_hash(nil)).to be_nil
    end

    it 'returns nil for empty hash' do
      expect(described_class.from_hash({})).to be_nil
    end

    it 'returns nil when no known keys present' do
      result = described_class.from_hash(unknown_key: 'value')

      expect(result).to be_nil
    end

    it 'filters unknown keys' do
      params = described_class.from_hash(
        max_tokens: 4096,
        temperature: 0.7,
        unknown_param: 'should_be_filtered',
        another_unknown: 123
      )

      expect(params.max_tokens).to eq(4096)
      expect(params.temperature).to eq(0.7)
    end

    it 'accepts all G18 standard params' do
      params = described_class.from_hash(
        max_tokens: 4096,
        max_thinking_tokens: 10_000,
        temperature: 0.7,
        top_p: 0.95,
        top_k: 50,
        stop_sequences: ['END'],
        seed: 42,
        frequency_penalty: 0.5,
        presence_penalty: 0.1,
        response_format: { type: 'json_object' }
      )

      expect(params.max_tokens).to eq(4096)
      expect(params.max_thinking_tokens).to eq(10_000)
      expect(params.temperature).to eq(0.7)
      expect(params.top_p).to eq(0.95)
      expect(params.top_k).to eq(50)
      expect(params.stop_sequences).to eq(['END'])
      expect(params.seed).to eq(42)
      expect(params.frequency_penalty).to eq(0.5)
      expect(params.presence_penalty).to eq(0.1)
      expect(params.response_format).to eq({ type: 'json_object' })
    end
  end

  describe '#to_h' do
    it 'serializes to compact hash' do
      params = described_class.new(
        max_tokens: 4096, temperature: 0.7,
        max_thinking_tokens: nil, top_p: nil, top_k: nil,
        stop_sequences: nil, seed: nil,
        frequency_penalty: nil, presence_penalty: nil,
        response_format: nil
      )
      hash = params.to_h

      expect(hash).to eq(max_tokens: 4096, temperature: 0.7)
    end

    it 'includes all non-nil fields' do
      params = described_class.new(
        max_tokens: 4096, max_thinking_tokens: 10_000,
        temperature: 0.7, top_p: 0.95, top_k: 50,
        stop_sequences: ['END'], seed: 42,
        frequency_penalty: 0.5, presence_penalty: 0.1,
        response_format: { type: 'json_object' }
      )
      hash = params.to_h

      expect(hash).to include(
        max_tokens: 4096, max_thinking_tokens: 10_000,
        temperature: 0.7, top_p: 0.95, top_k: 50,
        stop_sequences: ['END'], seed: 42,
        frequency_penalty: 0.5, presence_penalty: 0.1,
        response_format: { type: 'json_object' }
      )
    end
  end

  describe 'round-trip' do
    it 'preserves values through from_hash/to_h' do
      original = { max_tokens: 4096, temperature: 0.7, top_p: 0.95 }
      params = described_class.from_hash(original)
      serialized = params.to_h

      expect(serialized).to eq(original)
    end

    it 'normalizes provider keys through round-trip' do
      original = { max_output_tokens: 2048, budget_tokens: 5000, stop: ['END'] }
      params = described_class.from_hash(original)
      serialized = params.to_h

      expect(serialized[:max_tokens]).to eq(2048)
      expect(serialized[:max_thinking_tokens]).to eq(5000)
      expect(serialized[:stop_sequences]).to eq(['END'])
    end
  end
end
