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

    # SSOT / one-oracle for cross-provider thinking (NxN best-effort): a client
    # dialect supplies only ONE axis (Anthropic = budget_tokens only, OpenAI =
    # effort only). Every provider translator must still get a usable value for
    # whichever axis IT needs, so thinking survives ANY client×provider pair
    # instead of being silently dropped. The conversion lives HERE (the canonical
    # config), not scattered/one-directional in each translator. Derived accessors
    # do NOT mutate stored state or #to_h — they only fill the gap on read.
    describe 'derived cross-axis accessors' do
      it 'derives budget from effort when only effort was set' do
        expect(config_class.build(effort: 'low').resolved_budget).to eq(1024)
        expect(config_class.build(effort: 'medium').resolved_budget).to eq(8192)
        expect(config_class.build(effort: 'high').resolved_budget).to eq(16_384)
      end

      it 'derives effort from budget by band (< medium=low, < high=medium, else high)' do
        expect(config_class.build(budget: 500).resolved_effort).to eq('low') # < 8192
        expect(config_class.build(budget: 10_000).resolved_effort).to eq('medium') # 8192..16383
        expect(config_class.build(budget: 20_000).resolved_effort).to eq('high') # >= 16384
      end

      it 'prefers the explicitly-set value over derivation' do
        c = config_class.build(effort: 'high', budget: 2048)
        expect(c.resolved_budget).to eq(2048)
        expect(c.resolved_effort).to eq('high')
      end

      it 'returns nil derivations when neither axis is set' do
        c = config_class.build
        expect(c.resolved_budget).to be_nil
        expect(c.resolved_effort).to be_nil
      end

      it 'does not fabricate the missing axis in to_h (stored state stays faithful)' do
        expect(config_class.build(effort: 'high').to_h).to eq(effort: 'high')
        expect(config_class.build(budget: 2048).to_h).to eq(budget: 2048)
      end
    end
  end
end
