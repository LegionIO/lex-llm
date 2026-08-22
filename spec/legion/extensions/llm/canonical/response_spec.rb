# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::Response do
  let(:type_class) { described_class }
  let(:auto_generated_members) { [] }
  let(:type_source) do
    {
      text: 'I am done',
      thinking: { content: 'reasoning', signature: 'sig-1' },
      tool_calls: [{ name: 'get_weather', arguments: { location: 'sf' } }],
      usage: { input_tokens: 12, output_tokens: 10 },
      stop_reason: 'end_turn',
      model: 'fake-model',
      routing: { lane_id: 'lane:v1:abc' },
      metadata: { origin: 'provider' }
    }
  end

  it_behaves_like 'a canonical type'

  describe 'H1 — .new is as strict as the factories' do
    it 'rejects a poison stop_reason' do
      expect { described_class.new(text: 'x', stop_reason: :bogus_reason) }
        .to raise_error(ArgumentError, /Invalid stop_reason/)
    end

    it 'rejects a wrong-class usage member' do
      expect { described_class.new(usage: 'nope') }
        .to raise_error(ArgumentError, /usage expected Hash, got String/)
    end
  end

  describe 'T5 — stop_reason enum (validated in both factories)' do
    it 'accepts every canonical stop reason in both factories' do
      described_class::STOP_REASONS.each do |reason|
        expect(described_class.build(text: 'x', stop_reason: reason).stop_reason).to eq(reason)
        expect(described_class.from_hash(text: 'x', stop_reason: reason.to_s).stop_reason).to eq(reason)
      end
    end

    it 'raises on an invalid stop reason in both factories' do
      expect { described_class.build(stop_reason: :invalid_reason, text: 'test') }
        .to raise_error(ArgumentError, /Invalid stop_reason/)
      expect { described_class.from_hash(stop_reason: 'bogus', text: 'test') }
        .to raise_error(ArgumentError, /Invalid stop_reason/)
    end
  end

  describe 'O03a — finish_reason alias deleted' do
    it 'does not translate finish_reason (it folds into metadata)' do
      response = described_class.from_hash(text: 'x', finish_reason: 'stop')
      expect(response.stop_reason).to be_nil
      expect(response.metadata).to eq(finish_reason: 'stop')
    end
  end

  describe 'L2 — build and from_hash share the member normalizers (T7)' do
    it 'normalizes tool_calls / usage / thinking identically' do
      raw_tool_calls = [{ id: 'tc_1', name: 'x', arguments: { a: 1 } }]
      via_build = described_class.build(
        tool_calls: raw_tool_calls,
        usage: { input_tokens: 3 },
        thinking: { content: 'hmm' }
      )
      via_hash = described_class.from_hash(
        tool_calls: raw_tool_calls,
        usage: { input_tokens: 3 },
        thinking: { content: 'hmm' }
      )
      expect(via_build.tool_calls).to eq(via_hash.tool_calls)
      expect(via_build.usage).to eq(via_hash.usage)
      expect(via_build.thinking).to eq(via_hash.thinking)
    end

    it 'raises on wrong-class members' do
      expect { described_class.build(usage: 'nope') }
        .to raise_error(ArgumentError, /usage expected Hash, got String/)
      expect { described_class.from_hash(tool_calls: 'nope') }
        .to raise_error(ArgumentError, /tool_calls expected Array, got String/)
    end
  end

  it 'defaults to an empty canonical response from {}' do
    response = described_class.from_hash({})
    expect(response.text).to eq('')
    expect(response.tool_calls).to eq([])
    expect(response.stop_reason).to be_nil
  end

  it 'is the provider-boundary contract: error? and tool_call? predicates' do
    expect(described_class.build(stop_reason: :error).error?).to be(true)
    tc = Legion::Extensions::Llm::Canonical::ToolCall.build(name: 'x')
    expect(described_class.build(tool_calls: [tc]).tool_call?).to be(true)
  end
end
