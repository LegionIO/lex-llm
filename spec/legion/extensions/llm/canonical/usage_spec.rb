# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::Usage do
  describe '.from_hash' do
    it 'returns a Usage instance with canonical fields' do
      usage = described_class.from_hash(input_tokens: 100, output_tokens: 50)

      expect(usage).to be_a(described_class)
      expect(usage.input_tokens).to eq(100)
      expect(usage.output_tokens).to eq(50)
      expect(usage.cache_read_tokens).to be_nil
      expect(usage.cache_write_tokens).to be_nil
      expect(usage.thinking_tokens).to be_nil
      expect(usage.units).to eq({})
    end

    it 'normalizes legacy key names' do
      usage = described_class.from_hash(
        input: 200, output: 100, cached: 50, cache_creation: 25, thinking: 10
      )

      expect(usage.input_tokens).to eq(200)
      expect(usage.output_tokens).to eq(100)
      expect(usage.cache_read_tokens).to eq(50)
      expect(usage.cache_write_tokens).to eq(25)
      expect(usage.thinking_tokens).to eq(10)
    end

    it 'normalizes prompt_tokens/completion_tokens aliases' do
      usage = described_class.from_hash(prompt_tokens: 300, completion_tokens: 150)

      expect(usage.input_tokens).to eq(300)
      expect(usage.output_tokens).to eq(150)
    end

    it 'normalizes reasoning alias for thinking_tokens' do
      usage = described_class.from_hash(reasoning: 75)

      expect(usage.thinking_tokens).to eq(75)
    end

    it 'handles string keys' do
      usage = described_class.from_hash('input_tokens' => '100', 'output_tokens' => '50')

      expect(usage.input_tokens).to eq('100')
      expect(usage.output_tokens).to eq('50')
    end

    it 'returns nil for nil source' do
      expect(described_class.from_hash(nil)).to be_nil
    end

    it 'returns nil for empty hash' do
      expect(described_class.from_hash({})).to be_nil
    end

    it 'preserves units extension point' do
      units = { images: 3, characters: 1500 }
      usage = described_class.from_hash(input_tokens: 10, units: units)

      expect(usage.units).to eq(units)
    end
  end

  describe '#to_h' do
    it 'serializes to compact hash' do
      usage = described_class.new(
        input_tokens: 100, output_tokens: 50,
        cache_read_tokens: nil, cache_write_tokens: nil,
        thinking_tokens: nil, units: {}
      )
      hash = usage.to_h

      expect(hash).to eq(input_tokens: 100, output_tokens: 50, units: {})
    end

    it 'includes all non-nil fields' do
      usage = described_class.new(
        input_tokens: 200, output_tokens: 100,
        cache_read_tokens: 50, cache_write_tokens: 25,
        thinking_tokens: 10, units: { images: 2 }
      )
      hash = usage.to_h

      expect(hash).to include(
        input_tokens: 200, output_tokens: 100,
        cache_read_tokens: 50, cache_write_tokens: 25,
        thinking_tokens: 10, units: { images: 2 }
      )
    end
  end

  describe '#total_tokens' do
    it 'sums all token categories' do
      usage = described_class.new(
        input_tokens: 100, output_tokens: 50,
        cache_read_tokens: 20, cache_write_tokens: 10,
        thinking_tokens: 5, units: {}
      )

      expect(usage.total_tokens).to eq(185)
    end

    it 'ignores nil values' do
      usage = described_class.new(
        input_tokens: 100, output_tokens: 50,
        cache_read_tokens: nil, cache_write_tokens: nil,
        thinking_tokens: nil, units: {}
      )

      expect(usage.total_tokens).to eq(150)
    end
  end

  describe 'round-trip' do
    it 'preserves values through from_hash/to_h' do
      original = { input_tokens: 100, output_tokens: 50, cache_read_tokens: 10 }
      usage = described_class.from_hash(original)
      serialized = usage.to_h

      expect(serialized[:input_tokens]).to eq(100)
      expect(serialized[:output_tokens]).to eq(50)
      expect(serialized[:cache_read_tokens]).to eq(10)
    end

    it 'preserves legacy key normalization through round-trip' do
      original = { input: 200, output: 100, cached: 50 }
      usage = described_class.from_hash(original)
      serialized = usage.to_h

      expect(serialized[:input_tokens]).to eq(200)
      expect(serialized[:output_tokens]).to eq(100)
      expect(serialized[:cache_read_tokens]).to eq(50)
    end
  end
end
