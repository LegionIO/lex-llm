# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::Thinking do
  describe '.from_hash' do
    it 'returns a Thinking instance with content and signature' do
      thinking = described_class.from_hash(content: 'reasoning here', signature: 'sig-abc')

      expect(thinking).to be_a(described_class)
      expect(thinking.content).to eq('reasoning here')
      expect(thinking.signature).to eq('sig-abc')
    end

    it 'handles string keys' do
      thinking = described_class.from_hash('content' => 'reasoning', 'signature' => 'sig-123')

      expect(thinking.content).to eq('reasoning')
      expect(thinking.signature).to eq('sig-123')
    end

    it 'returns nil for nil source' do
      expect(described_class.from_hash(nil)).to be_nil
    end

    it 'returns nil for empty content and signature' do
      result = described_class.from_hash(content: '', signature: '')

      expect(result).to be_nil
    end

    it 'returns nil when both fields are nil' do
      result = described_class.from_hash(content: nil, signature: nil)

      expect(result).to be_nil
    end

    it 'returns instance with only content' do
      thinking = described_class.from_hash(content: 'just reasoning')

      expect(thinking.content).to eq('just reasoning')
      expect(thinking.signature).to be_nil
    end

    it 'returns instance with only signature' do
      thinking = described_class.from_hash(signature: 'sig-only')

      expect(thinking.content).to be_nil
      expect(thinking.signature).to eq('sig-only')
    end
  end

  describe '#to_h' do
    it 'serializes to compact hash' do
      thinking = described_class.new(content: 'reasoning', signature: 'sig-1')
      hash = thinking.to_h

      expect(hash).to eq(content: 'reasoning', signature: 'sig-1')
    end

    it 'omits nil values' do
      thinking = described_class.new(content: 'reasoning', signature: nil)
      hash = thinking.to_h

      expect(hash).to eq(content: 'reasoning')
    end
  end

  describe '#empty?' do
    it 'returns true when both fields are nil' do
      thinking = described_class.new(content: nil, signature: nil)
      expect(thinking.empty?).to be true
    end

    it 'returns false when content is present' do
      thinking = described_class.new(content: 'reasoning', signature: nil)
      expect(thinking.empty?).to be false
    end
  end

  describe 'round-trip' do
    it 'preserves content and signature through from_hash/to_h' do
      original = { content: 'deep reasoning', signature: 'sig-xyz' }
      thinking = described_class.from_hash(original)
      serialized = thinking.to_h

      expect(serialized).to eq(original)
    end
  end

  describe '::Config' do
    let(:config_class) { Legion::Extensions::Llm::Canonical::Thinking::Config }

    describe '.build' do
      it 'creates a config with effort and budget' do
        config = config_class.build(effort: 'high', budget: 10_000)

        expect(config.effort).to eq('high')
        expect(config.budget).to eq(10_000)
        expect(config.enabled?).to be true
      end

      it 'converts symbol effort to string' do
        config = config_class.build(effort: :high)

        expect(config.effort).to eq('high')
      end

      it 'creates disabled config when no values' do
        config = config_class.build

        expect(config.enabled?).to be false
      end
    end

    describe '.from_hash' do
      it 'parses config from hash' do
        config = config_class.from_hash(effort: 'medium', budget: 5000)

        expect(config.effort).to eq('medium')
        expect(config.budget).to eq(5000)
      end

      it 'handles string keys' do
        config = config_class.from_hash('effort' => 'low')

        expect(config.effort).to eq('low')
      end

      it 'returns nil for nil source' do
        expect(config_class.from_hash(nil)).to be_nil
      end

      it 'returns nil for empty hash' do
        expect(config_class.from_hash({})).to be_nil
      end
    end

    describe '#to_h' do
      it 'serializes to compact hash' do
        config = config_class.build(effort: 'high', budget: 10_000)
        expect(config.to_h).to eq(effort: 'high', budget: 10_000)
      end

      it 'omits nil values' do
        config = config_class.build(effort: 'low')
        expect(config.to_h).to eq(effort: 'low')
      end
    end
  end
end
