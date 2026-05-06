# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::StreamAccumulator do
  describe '#add' do
    it 'handles tool call deltas that omit arguments' do
      accumulator = described_class.new
      tool_call = Legion::Extensions::Llm::ToolCall.new(id: 'call_1', name: 'weather', arguments: nil)
      chunk = Legion::Extensions::Llm::Chunk.new(role: :assistant, content: nil, tool_calls: { 'call_1' => tool_call })

      expect { accumulator.add(chunk) }.not_to raise_error

      message = accumulator.to_message(nil)
      expect(message.tool_calls['call_1'].arguments).to eq({})
    end

    it 'treats content before an unmatched closing think tag as thinking' do
      accumulator = described_class.new
      chunk = Legion::Extensions::Llm::Chunk.new(
        role: :assistant,
        content: "internal\n</think>\n\nHello"
      )

      accumulator.add(chunk)

      message = accumulator.to_message(nil)
      expect(message.content).to eq('Hello')
      expect(message.thinking.text).to eq("internal\n")
    end
  end
end
