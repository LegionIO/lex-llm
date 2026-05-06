# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Message do
  describe '#content' do
    it 'normalizes nil content to empty string for assistant tool-call messages' do
      tool_call = Legion::Extensions::Llm::ToolCall.new(id: 'call_1', name: 'weather', arguments: {})
      message = described_class.new(role: :assistant, content: nil, tool_calls: { 'call_1' => tool_call })

      expect(message.content).to eq('')
    end

    it 'keeps nil content for messages without tool calls' do
      message = described_class.new(role: :assistant, content: nil, tool_calls: nil)

      expect(message.content).to be_nil
    end
  end

  describe '#to_h' do
    it 'does not expose hidden thinking text in public message serialization' do
      message = described_class.new(
        role: :assistant,
        content: 'visible',
        thinking: Legion::Extensions::Llm::Thinking.build(text: 'hidden', signature: 'sig-1'),
        raw: { reasoning_content: 'raw hidden' }
      )

      expect(message.to_h).to eq(role: :assistant, content: 'visible')
      expect(Legion::JSON.dump(message.to_h)).not_to include('hidden', 'reasoning_content', 'sig-1')
    end

    it 'keeps hidden thinking text available through internal message serialization' do
      message = described_class.new(
        role: :assistant,
        content: 'visible',
        thinking: Legion::Extensions::Llm::Thinking.build(text: 'hidden', signature: 'sig-1'),
        raw: { reasoning_content: 'raw hidden' }
      )

      expect(message.to_internal_h).to include(
        role: :assistant,
        content: 'visible',
        thinking: 'hidden',
        thinking_signature: 'sig-1',
        raw: { reasoning_content: 'raw hidden' }
      )
    end
  end

  describe Legion::Extensions::Llm::Chunk do
    it 'does not expose hidden thinking text in public chunk serialization' do
      chunk = described_class.new(
        role: :assistant,
        content: 'visible',
        thinking: Legion::Extensions::Llm::Thinking.build(text: 'hidden')
      )

      expect(chunk.to_h).to eq(role: :assistant, content: 'visible')
      expect(chunk.to_internal_h).to include(thinking: 'hidden')
    end
  end
end
