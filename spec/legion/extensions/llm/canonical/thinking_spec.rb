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
end
