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

    it 'drops malformed accumulated tool arguments instead of raising' do
      accumulator = described_class.new
      tool_call = Legion::Extensions::Llm::ToolCall.new(id: 'call_1', name: 'weather', arguments: '{"city"')
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

    it 'does not leak streamed thinking tag variants split across chunks' do
      accumulator = described_class.new
      stream = ['<thinking>', 'internal', '</thinking>Hello']

      filtered = stream.filter_map do |content|
        chunk = Legion::Extensions::Llm::Chunk.new(role: :assistant, content: content)
        accumulator.add(chunk)
        accumulator.filtered_chunk(chunk)
      end

      message = accumulator.to_message(nil)
      expect(filtered.filter_map(&:content)).to eq(['Hello'])
      expect(filtered.filter_map { |chunk| chunk.thinking&.text }.join).to eq('internal')
      expect(message.content).to eq('Hello')
      expect(message.thinking.text).to eq('internal')
    end

    it 'does not stream untagged local-model reasoning preambles as content' do
      accumulator = described_class.new
      stream = [
        'The user is just saying "test".',
        ' Let me respond simply and confirm things are working.',
        "\n\nHey! Things are working on my end."
      ]

      filtered = stream.filter_map do |content|
        chunk = Legion::Extensions::Llm::Chunk.new(role: :assistant, content: content)
        accumulator.add(chunk)
        accumulator.filtered_chunk(chunk)
      end

      message = accumulator.to_message(nil)
      expect(filtered.filter_map(&:content)).to eq(['Hey! Things are working on my end.'])
      expect(filtered.filter_map { |chunk| chunk.thinking&.text }.join)
        .to eq('The user is just saying "test". Let me respond simply and confirm things are working.')
      expect(message.content).to eq('Hey! Things are working on my end.')
      expect(message.thinking.text)
        .to eq('The user is just saying "test". Let me respond simply and confirm things are working.')
    end

    it 'releases normal text that starts like a possible reasoning preamble' do
      accumulator = described_class.new
      stream = [
        'The user guide covers setup.',
        "\n\nFollow the install section first."
      ]

      filtered = stream.filter_map do |content|
        chunk = Legion::Extensions::Llm::Chunk.new(role: :assistant, content: content)
        accumulator.add(chunk)
        accumulator.filtered_chunk(chunk)
      end

      message = accumulator.to_message(nil)
      expected = "The user guide covers setup.\n\nFollow the install section first."
      expect(filtered.filter_map(&:content).join).to eq(expected)
      expect(message.content).to eq(expected)
      expect(message.thinking).to be_nil
    end
  end

  describe '#filtered_chunk' do
    it 'returns a chunk for a plain text delta' do
      accumulator = described_class.new
      chunk = Legion::Extensions::Llm::Chunk.new(role: :assistant, content: 'Hello', model_id: 'm')

      accumulator.add(chunk)
      filtered = accumulator.filtered_chunk(chunk)

      expect(filtered).not_to be_nil
      expect(filtered.content.to_s).to eq('Hello')
    end
  end

  describe '#flush_pending_chunk' do
    it 'returns nil when nothing is buffered' do
      accumulator = described_class.new
      chunk = Legion::Extensions::Llm::Chunk.new(role: :assistant, content: 'Hello', model_id: 'm')
      accumulator.add(chunk)

      expect(accumulator.flush_pending_chunk).to be_nil
    end

    it 'releases text held by the untagged-preamble heuristic as a final delta' do
      accumulator = described_class.new
      deltas = []
      ['I can help', ' with that.'].each do |text|
        chunk = Legion::Extensions::Llm::Chunk.new(role: :assistant, content: text, model_id: 'm')
        accumulator.add(chunk)
        filtered = accumulator.filtered_chunk(chunk)
        deltas << filtered.content.to_s if filtered
      end

      final = accumulator.flush_pending_chunk
      deltas << final.content.to_s if final
      message = accumulator.to_message(nil)

      expect(deltas.join).to eq('I can help with that.')
      expect(message.content).to eq('I can help with that.')
    end

    it 'does not double-append flushed text in to_message' do
      accumulator = described_class.new
      chunk = Legion::Extensions::Llm::Chunk.new(role: :assistant, content: 'The answer', model_id: 'm')
      accumulator.add(chunk)

      accumulator.flush_pending_chunk
      message = accumulator.to_message(nil)

      expect(message.content).to eq('The answer')
    end
  end
end
