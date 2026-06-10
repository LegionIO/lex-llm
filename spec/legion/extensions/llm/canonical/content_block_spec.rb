# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::ContentBlock do
  describe '.text' do
    it 'creates a text content block' do
      block = described_class.text('hello world')

      expect(block.type).to eq(:text)
      expect(block.text).to eq('hello world')
    end

    it 'accepts cache_control' do
      block = described_class.text('hello', cache_control: { type: 'ephemeral' })

      expect(block.cache_control).to eq({ type: 'ephemeral' })
    end
  end

  describe '.thinking' do
    it 'creates a thinking content block' do
      block = described_class.thinking('reasoning here')

      expect(block.type).to eq(:thinking)
      expect(block.text).to eq('reasoning here')
    end
  end

  describe '.tool_use' do
    it 'creates a tool_use content block' do
      block = described_class.tool_use(id: 'toolu-1', name: 'search', input: { query: 'test' })

      expect(block.type).to eq(:tool_use)
      expect(block.id).to eq('toolu-1')
      expect(block.name).to eq('search')
      expect(block.input).to eq({ query: 'test' })
    end
  end

  describe '.tool_result' do
    it 'creates a tool_result content block' do
      block = described_class.tool_result(tool_use_id: 'toolu-1', content: 'result')

      expect(block.type).to eq(:tool_result)
      expect(block.tool_use_id).to eq('toolu-1')
      expect(block.text).to eq('result')
      expect(block.is_error).to be false
    end

    it 'marks error results' do
      block = described_class.tool_result(tool_use_id: 'toolu-1', content: 'error', is_error: true)

      expect(block.is_error).to be true
    end
  end

  describe '.image' do
    it 'creates an image content block with media_type (G20a)' do
      block = described_class.image(data: 'base64data', media_type: 'image/png')

      expect(block.type).to eq(:image)
      expect(block.data).to eq('base64data')
      expect(block.media_type).to eq('image/png')
      expect(block.source_type).to eq(:base64)
    end

    it 'accepts custom source_type and detail' do
      block = described_class.image(data: 'img.png', media_type: 'image/png', source_type: :url, detail: 'high')

      expect(block.source_type).to eq(:url)
      expect(block.detail).to eq('high')
    end
  end

  describe '.from_hash' do
    it 'parses a content block from hash' do
      block = described_class.from_hash(type: 'text', text: 'hello')

      expect(block.type).to eq(:text)
      expect(block.text).to eq('hello')
    end

    it 'handles string keys' do
      block = described_class.from_hash('type' => 'thinking', 'text' => 'reasoning')

      expect(block.type).to eq(:thinking)
      expect(block.text).to eq('reasoning')
    end

    it 'returns nil for nil source' do
      expect(described_class.from_hash(nil)).to be_nil
    end

    it 'preserves all fields' do
      hash = {
        type: 'tool_use',
        id: 'toolu-1',
        name: 'search',
        input: { query: 'test' },
        cache_control: { type: 'ephemeral' }
      }
      block = described_class.from_hash(hash)

      expect(block.type).to eq(:tool_use)
      expect(block.id).to eq('toolu-1')
      expect(block.name).to eq('search')
      expect(block.input).to eq({ query: 'test' })
      expect(block.cache_control).to eq({ type: 'ephemeral' })
    end
  end

  describe '#to_h' do
    it 'serializes to compact hash' do
      block = described_class.text('hello')
      hash = block.to_h

      expect(hash).to eq(type: :text, text: 'hello')
    end

    it 'omits nil values' do
      block = described_class.new(
        type: :text, text: 'hello', data: nil, source_type: nil,
        media_type: nil, detail: nil, name: nil, file_id: nil,
        id: nil, input: nil, tool_use_id: nil, is_error: nil,
        source: nil, start_index: nil, end_index: nil,
        code: nil, message: nil, cache_control: nil
      )
      hash = block.to_h

      expect(hash).to eq(type: :text, text: 'hello')
    end
  end

  describe 'type predicates' do
    it 'identifies text blocks' do
      block = described_class.text('hello')
      expect(block.text?).to be true
      expect(block.thinking?).to be false
      expect(block.tool_use?).to be false
      expect(block.tool_result?).to be false
    end

    it 'identifies thinking blocks' do
      block = described_class.thinking('reasoning')
      expect(block.thinking?).to be true
      expect(block.text?).to be false
    end

    it 'identifies tool_use blocks' do
      block = described_class.tool_use(id: '1', name: 'search', input: {})
      expect(block.tool_use?).to be true
    end

    it 'identifies tool_result blocks' do
      block = described_class.tool_result(tool_use_id: '1', content: 'result')
      expect(block.tool_result?).to be true
    end
  end

  describe 'CONTENT_BLOCK_TYPES' do
    it 'includes all expected types' do
      expect(described_class::CONTENT_BLOCK_TYPES).to include(
        :text, :thinking, :tool_use, :tool_result, :image, :audio, :video
      )
    end
  end

  describe 'round-trip' do
    it 'preserves text block through from_hash/to_h' do
      original = { type: 'text', text: 'hello world' }
      block = described_class.from_hash(original)
      serialized = block.to_h

      expect(serialized[:type]).to eq(:text)
      expect(serialized[:text]).to eq('hello world')
    end
  end
end
