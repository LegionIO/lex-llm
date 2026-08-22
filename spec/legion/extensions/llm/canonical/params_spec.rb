# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::Params do
  let(:type_class) { described_class }
  let(:auto_generated_members) { [] }
  let(:type_source) do
    {
      max_tokens: 1024,
      max_thinking_tokens: 512,
      temperature: 0.7,
      top_p: 0.9,
      top_k: 40,
      stop_sequences: ['\n\n'],
      seed: 42,
      frequency_penalty: 0.1,
      presence_penalty: 0.2,
      response_format: { type: 'json_object' },
      metadata: { source: 'client' }
    }
  end

  it_behaves_like 'a canonical type'

  describe 'O03a — canonical keys only' do
    it 'does not translate provider spellings (they fold into metadata)' do
      params = described_class.from_hash(max_output_tokens: 999, num_predict: 888, stop: ['x'])
      expect(params.max_tokens).to be_nil
      expect(params.max_thinking_tokens).to be_nil
      expect(params.stop_sequences).to be_nil
      expect(params.metadata).to eq(max_output_tokens: 999, num_predict: 888, stop: ['x'])
    end
  end

  describe 'H1/M3 — wire-type validation in every constructor' do
    it 'rejects garbage numeric members in build, from_hash, and .new' do
      expect { described_class.build(max_tokens: 'abc') }
        .to raise_error(ArgumentError, /max_tokens expected Integer, got String/)
      expect { described_class.from_hash(temperature: :hot) }
        .to raise_error(ArgumentError, /temperature expected Numeric, got Symbol/)
      expect { described_class.new(seed: -3.5) }
        .to raise_error(ArgumentError, /seed expected Integer, got Float/)
    end

    it 'rejects wrong-class stop_sequences and response_format' do
      expect { described_class.new(stop_sequences: 42) }
        .to raise_error(ArgumentError, /stop_sequences expected String \| Array, got Integer/)
      expect { described_class.build(response_format: 42) }
        .to raise_error(ArgumentError, /response_format expected String \| Hash, got Integer/)
    end
  end

  describe 'construction law' do
    it 'from_hash({}) is a valid all-nil Params (never nil)' do
      params = described_class.from_hash({})
      expect(params).to be_a(described_class)
      expect(params.max_tokens).to be_nil
      expect(params.temperature).to be_nil
    end

    it 'builds from keyword args' do
      params = described_class.build(temperature: 1.0)
      expect(params.temperature).to eq(1.0)
    end

    it 'build and from_hash share one normalization path (T7)' do
      via_build = described_class.build(temperature: 0.5, metadata: { a: 1 })
      via_hash = described_class.from_hash(temperature: 0.5, metadata: { a: 1 })
      expect(via_build).to eq(via_hash)
    end

    it 'survives build → to_h → JSON → from_hash (T4)' do
      params = described_class.build(temperature: 0.5, stop_sequences: ['stop'])
      round_tripped = described_class.from_hash(Legion::JSON.load(Legion::JSON.dump(params.to_h)))
      expect(round_tripped).to eq(params)
    end
  end
end
