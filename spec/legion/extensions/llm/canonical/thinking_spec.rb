# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::Thinking do
  let(:type_class) { described_class }
  let(:auto_generated_members) { [] }
  let(:type_source) do
    { content: 'reasoning here', signature: 'sig-abc', metadata: { origin: 'provider' } }
  end

  it_behaves_like 'a canonical type'

  describe 'T5/T4 — construction law' do
    it 'builds from keyword args' do
      thinking = described_class.build(content: 'reasoning', signature: 'sig')
      expect(thinking.content).to eq('reasoning')
      expect(thinking.signature).to eq('sig')
    end

    it 'normalizes empty strings to nil (absence, not data — 04 §8)' do
      thinking = described_class.build(content: '', signature: '')
      expect(thinking.content).to be_nil
      expect(thinking.signature).to be_nil
      expect(thinking.empty?).to be(true)
    end

    it 'raises on a wrong-class member' do
      expect { described_class.build(content: 42) }
        .to raise_error(ArgumentError, /content expected String, got Integer/)
    end

    it 'survives build → to_h → JSON → from_hash (T4 signature)' do
      thinking = described_class.build(content: 'x', signature: 'sig-1')
      round_tripped = described_class.from_hash(Legion::JSON.load(Legion::JSON.dump(thinking.to_h)))
      expect(round_tripped.content).to eq('x')
      expect(round_tripped.signature).to eq('sig-1')
    end
  end

  describe Legion::Extensions::Llm::Canonical::Thinking::Config do
    subject(:config_class) { described_class }

    let(:type_class) { described_class }
    let(:auto_generated_members) { [] }
    let(:type_source) do
      { effort: 'high', budget: 4096, metadata: { source: 'client' } }
    end

    it_behaves_like 'a canonical type'

    it 'converts from a plain class to a Data with one name (04 §8)' do
      expect(config_class).to be_a(Class)
      expect(config_class.new(effort: 'low', budget: nil, metadata: {})).to be_a(config_class)
    end

    it 'normalizes symbol effort to String' do
      config = config_class.build(effort: :low)
      expect(config.effort).to eq('low')
    end

    it 'raises on a wrong-class effort' do
      expect { config_class.build(effort: 3) }
        .to raise_error(ArgumentError, /effort expected String, got Integer/)
    end

    it 'keeps the effort<->budget SSOT conversions' do
      expect(config_class.build(effort: 'low').resolved_budget).to eq(1024)
      expect(config_class.build(effort: 'medium').resolved_budget).to eq(8192)
      expect(config_class.build(effort: 'high').resolved_budget).to eq(16_384)
      expect(config_class.build(budget: 512).resolved_effort).to eq('low')
      expect(config_class.build(budget: 8192).resolved_effort).to eq('medium')
      expect(config_class.build(budget: 16_384).resolved_effort).to eq('high')
    end

    it 'is enabled only when an axis is set' do
      expect(config_class.build(effort: 'low').enabled?).to be(true)
      expect(config_class.build(budget: 1).enabled?).to be(true)
      expect(config_class.build.enabled?).to be(false)
    end

    it 'to_h is faithful to what was set (no fabricated axis)' do
      expect(config_class.build(effort: 'low').to_h).to eq(effort: 'low', metadata: {})
    end
  end
end
