# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::ContentBlock do
  let(:type_class) { described_class }
  let(:auto_generated_members) { [] }
  let(:type_source) do
    { type: 'text', text: 'hello block', metadata: { origin: 'provider' } }
  end

  it_behaves_like 'a canonical type'

  describe 'O03a — no type aliases' do
    it 'does not translate output_text/input_text — untranslated dialect types raise (L4/L6)' do
      expect { described_class.from_hash(type: 'output_text', text: 'x') }
        .to raise_error(ArgumentError, /Invalid type: :output_text/)
      expect { described_class.from_hash(type: 'input_text', text: 'x') }
        .to raise_error(ArgumentError, /Invalid type: :input_text/)
    end

    it 'raises on an unknown type value (L6)' do
      expect { described_class.build(type: :bogus) }
        .to raise_error(ArgumentError, /Invalid type: :bogus/)
    end
  end

  describe 'H1 — .new is as strict as the factories' do
    it 'rejects an unknown type in .new' do
      expect { described_class.new(type: :bogus, text: 'x') }
        .to raise_error(ArgumentError, /Invalid type: :bogus/)
    end
  end

  describe 'named factories (produce side)' do
    it 'builds a text block' do
      block = described_class.text('hi', cache_control: { type: :ephemeral })
      expect(block.type).to eq(:text)
      expect(block.text).to eq('hi')
      expect(block.cache_control).to eq(type: :ephemeral)
    end

    it 'builds thinking / tool_use / tool_result / image blocks' do
      expect(described_class.thinking('hmm').thinking?).to be(true)
      use = described_class.tool_use(id: 'tu_1', name: 'f', input: { a: 1 })
      expect(use.tool_use?).to be(true)
      expect(use.input).to eq(a: 1)
      result = described_class.tool_result(tool_use_id: 'tu_1', content: 'ok', is_error: true)
      expect(result.tool_result?).to be(true)
      expect(result.is_error).to be(true)
      image = described_class.image(data: 'AAA=', media_type: 'image/png')
      expect(image.type).to eq(:image)
      expect(image.media_type).to eq('image/png')
    end
  end

  describe 'F2 fix — no rescue-and-repair' do
    it 'raises on non-Hash from_hash input instead of fabricating a text block' do
      expect { described_class.from_hash('corrupted') }
        .to raise_error(ArgumentError, /expected Hash, got String/)
      expect { described_class.from_hash(nil) }
        .to raise_error(ArgumentError, /expected Hash, got NilClass/)
    end
  end

  describe 'source semantics at construction and rehydration' do
    it 'normalizes source enums through every constructor' do
      %i[new build from_hash].each do |constructor|
        %w[base64 url].each do |source_type|
          block = described_class.public_send(constructor, type: :image, source_type: source_type)
          expect(block.source_type).to eq(source_type.to_sym)
        end
      end
    end

    it 'rejects missing and unknown image source types through every constructor' do
      %i[new build from_hash].each do |constructor|
        expect { described_class.public_send(constructor, type: :image) }.to raise_error(ArgumentError, /source_type/)
        expect { described_class.public_send(constructor, type: :image, source_type: :file) }
          .to raise_error(ArgumentError, /Invalid source_type/)
      end
    end

    it 'preserves typed ordered content and image meaning across message JSON rehydration' do
      content = [
        described_class.text('compare', cache_control: { type: 'ephemeral' }),
        described_class.image(data: 'AAA=', media_type: 'image/png', detail: 'high'),
        described_class.image(data: 'https://example.org/image.png', media_type: nil, source_type: :url, detail: 'low')
      ]
      message = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: content)
      expect(message.content.first).to be(content.first)

      restored = Legion::Extensions::Llm::Canonical::Message.from_hash(Legion::JSON.load(Legion::JSON.dump(message)))

      expect(restored.content).to all(be_a(described_class))
      expect(restored.content).to eq(content)
    end
  end

  it 'text? is type == :text only (alias list deleted)' do
    expect(described_class.text('x').text?).to be(true)
    expect(described_class.thinking('x').text?).to be(false)
  end
end
