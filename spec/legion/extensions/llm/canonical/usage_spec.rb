# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::Usage do
  let(:type_class) { described_class }
  let(:auto_generated_members) { [] }
  let(:type_source) do
    {
      input_tokens: 100,
      output_tokens: 50,
      cache_read_tokens: 10,
      cache_write_tokens: 5,
      thinking_tokens: 25,
      units: { images: 1 },
      metadata: { source: 'provider' }
    }
  end

  it_behaves_like 'a canonical type'

  describe 'O03a — canonical keys only' do
    it 'does not translate provider spellings (they fold into metadata)' do
      usage = described_class.from_hash(prompt_tokens: 7, completion_tokens: 3)
      expect(usage.input_tokens).to be_nil
      expect(usage.output_tokens).to be_nil
      expect(usage.metadata).to eq(prompt_tokens: 7, completion_tokens: 3)
    end

    it 'does not dig nested *_tokens_details (edge concern)' do
      usage = described_class.from_hash(prompt_tokens_details: { cached_tokens: 9 })
      expect(usage.cache_read_tokens).to be_nil
      expect(usage.metadata).to eq(prompt_tokens_details: { cached_tokens: 9 })
    end
  end

  describe 'construction law' do
    it 'from_hash({}) is a valid all-nil Usage with empty units (never nil)' do
      usage = described_class.from_hash({})
      expect(usage).to be_a(described_class)
      expect(usage.input_tokens).to be_nil
      expect(usage.units).to eq({})
    end

    it 'builds from keyword args' do
      usage = described_class.build(input_tokens: 1, output_tokens: 2)
      expect(usage.total_tokens).to eq(3)
    end

    it 'survives build → to_h → JSON → from_hash (T4 units)' do
      usage = described_class.build(input_tokens: 1, units: { images: 2 })
      round_tripped = described_class.from_hash(Legion::JSON.load(Legion::JSON.dump(usage.to_h)))
      expect(round_tripped.units).to eq(images: 2)
      expect(round_tripped.input_tokens).to eq(1)
    end
  end
end
