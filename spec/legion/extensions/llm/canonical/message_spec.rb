# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::Message do
  let(:type_class) { described_class }
  let(:auto_generated_members) { %i[id timestamp] }
  let(:type_source) do
    {
      id: 'msg_1',
      role: 'user',
      content: 'hello there',
      tool_call_id: 'call_1',
      conversation_id: 'conv_1',
      cache_control: { type: 'ephemeral' },
      metadata: { origin: 'client' }
    }
  end

  it_behaves_like 'a canonical type'

  describe 'T5 — role enum (validated in both factories)' do
    it 'accepts the four roles as symbols or strings' do
      described_class::ROLES.each do |role|
        expect(described_class.build(role:).role).to eq(role)
        expect(described_class.from_hash(role: role.to_s).role).to eq(role)
      end
    end

    it 'raises on an unknown role in both factories' do
      expect { described_class.build(role: :bogus) }
        .to raise_error(ArgumentError, /Invalid role: :bogus/)
      expect { described_class.from_hash(role: 'bogus') }
        .to raise_error(ArgumentError, /Invalid role: :bogus/)
    end
  end

  describe 'L2 — one content/tool_calls normalizer shared by build and from_hash' do
    it 'normalizes raw-Hash tool_calls to Array<ToolCall> in both factories (T7)' do
      raw = [{ id: 'tc_1', name: 'get_weather', arguments: { location: 'sf' } }]
      via_build = described_class.build(role: :assistant, tool_calls: raw)
      via_hash = described_class.from_hash(role: 'assistant', tool_calls: raw)
      expect(via_build.tool_calls).to eq(via_hash.tool_calls)
      expect(via_build.tool_calls).to all(be_a(Legion::Extensions::Llm::Canonical::ToolCall))
      expect(via_build.tool_calls.first.name).to eq('get_weather')
    end

    it 'normalizes content block hashes in both factories' do
      via_build = described_class.build(role: :user, content: [{ type: 'text', text: 'hi' }])
      via_hash = described_class.from_hash(role: 'user', content: [{ type: 'text', text: 'hi' }])
      expect(via_build.content).to eq(via_hash.content)
      expect(via_build.content.first).to be_a(Legion::Extensions::Llm::Canonical::ContentBlock)
    end

    it 'raises on wrong-class content (the build-accepts-anything gap is closed)' do
      expect { described_class.build(content: 42) }
        .to raise_error(ArgumentError, /content expected String \| ContentBlock \| Array, got Integer/)
      expect { described_class.from_hash(content: 42) }
        .to raise_error(ArgumentError, /content expected String \| ContentBlock \| Array, got Integer/)
    end

    it 'rejects the legacy Hash tool_calls shape (Array is canonical)' do
      expect { described_class.build(tool_calls: { a: { name: 'x' } }) }
        .to raise_error(ArgumentError, /tool_calls expected Array, got Hash/)
    end
  end

  describe 'E01 — cache_control survives the full round-trip' do
    it 'survives build → to_h → JSON → from_hash (the fleet-wire variant)' do
      message = described_class.build(role: :user, content: 'hi', cache_control: { type: 'ephemeral' })
      wire = Legion::JSON.load(Legion::JSON.dump(message.to_h))
      expect(wire).to include(cache_control: { type: 'ephemeral' })
      expect(described_class.from_hash(wire).cache_control).to eq(type: 'ephemeral')
    end

    it 'is carried by to_h (no projection drop)' do
      message = described_class.build(role: :user, content: 'hi', cache_control: { type: 'ephemeral' })
      expect(message.to_h).to include(cache_control: { type: 'ephemeral' })
    end
  end

  describe 'F1 fix — unknown keys fold into metadata (never dropped)' do
    it 'folds unknowns on from_hash' do
      message = described_class.from_hash(role: 'user', content: 'hi', fleet_wire_key: 'kept')
      expect(message.metadata).to eq(fleet_wire_key: 'kept')
    end
  end

  describe 'F2 fix — wrap and to_provider_hash are deleted' do
    it 'exposes no wrap factory' do
      expect(described_class.respond_to?(:wrap)).to be(false)
    end

    it 'exposes no to_provider_hash projection (L9)' do
      expect(described_class.build(role: :user, content: 'x')).not_to respond_to(:to_provider_hash)
    end
  end

  it 'auto-generates msg_<24-hex> ids and timestamps when absent' do
    message = described_class.build(role: :user, content: 'x')
    expect(message.id).to match(/\Amsg_[0-9a-f]{24}\z/)
    expect(message.timestamp).to be_a(Time)
  end

  it 'extracts plain text from String and ContentBlock content' do
    expect(described_class.build(role: :user, content: 'plain').text).to eq('plain')
    blocks = [
      Legion::Extensions::Llm::Canonical::ContentBlock.text('a '),
      Legion::Extensions::Llm::Canonical::ContentBlock.thinking('hidden')
    ]
    expect(described_class.build(role: :user, content: blocks).text).to eq('a ')
  end
end
