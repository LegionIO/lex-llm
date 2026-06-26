# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::Message do
  describe '.build' do
    it 'creates a message with required fields' do
      msg = described_class.build(role: :user, content: 'hello')

      expect(msg.role).to eq(:user)
      expect(msg.content).to eq('hello')
      expect(msg.id).to start_with('msg_')
      expect(msg.status).to eq(:created)
      expect(msg.version).to eq(1)
    end

    it 'accepts all fields' do
      msg = described_class.build(
        id: 'msg-1',
        parent_id: 'msg-0',
        role: :assistant,
        content: 'response',
        tool_calls: [],
        conversation_id: 'conv-1'
      )

      expect(msg.id).to eq('msg-1')
      expect(msg.parent_id).to eq('msg-0')
      expect(msg.role).to eq(:assistant)
      expect(msg.conversation_id).to eq('conv-1')
    end

    it 'normalizes string role to symbol' do
      msg = described_class.build(role: 'user', content: 'hello')

      expect(msg.role).to eq(:user)
    end

    it 'rejects invalid roles' do
      expect do
        described_class.build(role: :invalid, content: 'hello')
      end.to raise_error(ArgumentError, /Invalid role/)
    end

    it 'defaults to user role' do
      msg = described_class.build(content: 'hello')

      expect(msg.role).to eq(:user)
    end

    it 'sets timestamp automatically' do
      msg = described_class.build(content: 'hello')

      expect(msg.timestamp).to be_a(Time)
    end
  end

  describe '.from_hash' do
    it 'parses from hash with symbol keys' do
      msg = described_class.from_hash(role: :user, content: 'hello')

      expect(msg.role).to eq(:user)
      expect(msg.content).to eq('hello')
    end

    it 'normalizes string role to symbol' do
      msg = described_class.from_hash(role: 'assistant', content: 'response')

      expect(msg.role).to eq(:assistant)
    end

    it 'parses content blocks from array of hashes' do
      msg = described_class.from_hash(
        role: :user,
        content: [{ type: 'text', text: 'hello' }]
      )

      expect(msg.content).to be_an(Array)
      expect(msg.content.first).to be_a(Legion::Extensions::Llm::Canonical::ContentBlock)
      expect(msg.content.first.type).to eq(:text)
    end

    it 'parses single content block from hash' do
      msg = described_class.from_hash(
        role: :user,
        content: { type: 'text', text: 'hello' }
      )

      expect(msg.content).to be_a(Legion::Extensions::Llm::Canonical::ContentBlock)
    end

    it 'parses tool calls from array of hashes' do
      msg = described_class.from_hash(
        role: :assistant,
        tool_calls: [{ name: 'search', arguments: { query: 'test' } }]
      )

      expect(msg.tool_calls).to be_an(Array)
      expect(msg.tool_calls.first).to be_a(Legion::Extensions::Llm::Canonical::ToolCall)
    end

    it 'handles string keys' do
      msg = described_class.from_hash('role' => 'user', 'content' => 'hello')

      expect(msg.role).to eq(:user)
      expect(msg.content).to eq('hello')
    end

    it 'returns nil for nil source' do
      expect(described_class.from_hash(nil)).to be_nil
    end
  end

  describe '.wrap' do
    it 'passes through existing Message instances' do
      msg = described_class.build(role: :user, content: 'hello')
      wrapped = described_class.wrap(msg)

      expect(wrapped).to eq(msg)
    end

    it 'parses Hash input' do
      wrapped = described_class.wrap({ role: :user, content: 'hello' })

      expect(wrapped).to be_a(described_class)
      expect(wrapped.content).to eq('hello')
    end

    it 'returns nil for unsupported input' do
      expect(described_class.wrap('hello')).to be_nil
    end
  end

  describe '#text' do
    it 'returns content when it is a String' do
      msg = described_class.build(role: :user, content: 'hello')

      expect(msg.text).to eq('hello')
    end

    it 'extracts text from ContentBlock array' do
      blocks = [
        Legion::Extensions::Llm::Canonical::ContentBlock.text('hello'),
        Legion::Extensions::Llm::Canonical::ContentBlock.text(' world')
      ]
      msg = described_class.build(role: :user, content: blocks)

      expect(msg.text).to eq('hello world')
    end

    it 'skips non-text blocks' do
      blocks = [
        Legion::Extensions::Llm::Canonical::ContentBlock.text('hello'),
        Legion::Extensions::Llm::Canonical::ContentBlock.thinking('reasoning')
      ]
      msg = described_class.build(role: :user, content: blocks)

      expect(msg.text).to eq('hello')
    end

    it 'returns empty string for nil content' do
      msg = described_class.build(role: :user, content: nil)

      expect(msg.text).to eq('')
    end

    it 'extracts text from output_text ContentBlock array (Responses API / Codex)' do
      msg = described_class.from_hash(
        role: :assistant,
        content: [{ type: 'output_text', text: "The seat templates don't" }]
      )

      expect(msg.text).to eq("The seat templates don't")
      expect(msg.text).not_to include('#<data')
      expect(msg.text).not_to include('ContentBlock')
    end

    it 'extracts text from mixed output_text and text blocks' do
      msg = described_class.from_hash(
        role: :assistant,
        content: [
          { type: 'output_text', text: 'first ' },
          { type: 'text', text: 'second' }
        ]
      )

      expect(msg.text).to eq('first second')
    end
  end

  describe '#to_h' do
    it 'serializes to compact hash' do
      msg = described_class.build(role: :user, content: 'hello')
      hash = msg.to_h

      expect(hash).to include(id: msg.id, role: :user, content: 'hello')
    end
  end

  describe '#to_provider_hash' do
    it 'returns minimal provider-facing hash' do
      msg = described_class.build(role: :user, content: 'hello')
      hash = msg.to_provider_hash

      expect(hash).to eq(role: 'user', content: 'hello')
    end
  end

  describe 'ROLES' do
    it 'includes all expected roles' do
      expect(described_class::ROLES).to eq(%i[system user assistant tool])
    end
  end

  describe 'round-trip' do
    it 'preserves values through from_hash/to_h' do
      original = { role: 'user', content: 'hello', conversation_id: 'conv-1' }
      msg = described_class.from_hash(original)
      serialized = msg.to_h

      expect(serialized[:role]).to eq(:user)
      expect(serialized[:content]).to eq('hello')
      expect(serialized[:conversation_id]).to eq('conv-1')
    end
  end
end
