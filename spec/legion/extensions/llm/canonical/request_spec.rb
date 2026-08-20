# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::Request do
  let(:type_class) { described_class }
  let(:auto_generated_members) { [:id] }
  let(:type_source) do
    {
      id: 'req_1',
      messages: [{ role: 'user', content: 'how are you' }],
      system: 'be brief',
      tools: [{ name: 'get_weather', description: 'd', parameters: { type: 'object', properties: {} } }],
      tool_choice: 'auto',
      params: { temperature: 0.5 },
      thinking: { effort: 'low' },
      stream: false,
      conversation_id: 'conv_1',
      caller: 'e2e',
      routing: { provider: 'fake' },
      metadata: { origin: 'client' }
    }
  end

  it_behaves_like 'a canonical type'

  describe 'F2 fix — strict message map (no silent drops)' do
    it 'normalizes Hash messages and passes Canonical through (T7)' do
      canonical = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')
      raw = { role: 'user', content: 'there' }
      via_build = described_class.build(messages: [canonical, raw])
      via_hash = described_class.from_hash(messages: [canonical, raw])
      expect(via_build.messages.map { |m| [m.role, m.content, m.class] })
        .to eq(via_hash.messages.map { |m| [m.role, m.content, m.class] })
      expect(via_build.messages).to all(be_a(Legion::Extensions::Llm::Canonical::Message))
    end

    it 'raises on non-Message/non-Hash elements (the filter_map drop is deleted)' do
      expect { described_class.build(messages: [42]) }
        .to raise_error(ArgumentError, /expected Hash, got Integer/)
      expect { described_class.build(messages: [nil]) }
        .to raise_error(ArgumentError, /expected Hash, got NilClass/)
      expect { described_class.from_hash(messages: ['str']) }
        .to raise_error(ArgumentError, /expected Hash, got String/)
    end

    it 'raises on a wrong-class messages member' do
      expect { described_class.build(messages: 'nope') }
        .to raise_error(ArgumentError, /messages expected Array, got String/)
    end
  end

  describe 'L2 — tools/params/thinking normalizers shared by both factories' do
    it 'normalizes tools to Hash<name, ToolDefinition> (T7)' do
      via_build = described_class.build(tools: [{ name: 'get_weather', parameters: {} }])
      via_hash = described_class.from_hash(tools: [{ name: 'get_weather', parameters: {} }])
      expect(via_build.tools).to eq(via_hash.tools)
      expect(via_build.tools.keys).to eq(%w[get_weather])
      expect(via_build.tools.values.first).to be_a(Legion::Extensions::Llm::Canonical::ToolDefinition)
    end

    it 'normalizes params to Canonical::Params and thinking to Thinking::Config' do
      request = described_class.build(params: { temperature: 1 }, thinking: { effort: 'high' })
      expect(request.params).to be_a(Legion::Extensions::Llm::Canonical::Params)
      expect(request.thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking::Config)
      expect(request.thinking.effort).to eq('high')
    end

    it 'raises on wrong-class params/thinking' do
      expect { described_class.build(params: 'nope') }
        .to raise_error(ArgumentError, /params expected Hash, got String/)
      expect { described_class.from_hash(thinking: 42) }
        .to raise_error(ArgumentError, /thinking expected Hash, got Integer/)
    end
  end

  describe 'T4 — member survival through the wire' do
    it 'survives build → to_h → JSON → from_hash' do
      request = described_class.build(
        messages: [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi',
                                                                     cache_control: { type: 'ephemeral' })],
        params: { temperature: 0.25 }
      )
      wire = Legion::JSON.load(Legion::JSON.dump(request.to_h))
      round_tripped = described_class.from_hash(wire)
      expect(round_tripped.messages.first.content).to eq('hi')
      expect(round_tripped.messages.first.cache_control).to eq(type: 'ephemeral')
      expect(round_tripped.params.temperature).to eq(0.25)
    end
  end

  it 'defaults stream false, routing {} and auto-generates req ids' do
    request = described_class.build(messages: [])
    expect(request.stream).to be(false)
    expect(request.routing).to eq({})
    expect(request.id).to match(/\Areq_[0-9a-f]{24}\z/)
    expect(request.messages).to eq([])
  end
end
