# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Model::Info do
  describe 'construction' do
    it 'creates an Info with all fields' do
      info = described_class.new(
        id: 'llama-3.1-8b',
        name: 'Llama 3.1 8B',
        provider: 'Ollama',
        instance: :worker_one,
        family: 'Llama',
        capabilities: %i[completion vision tools],
        context_length: 128_000,
        parameter_count: 8_000_000_000,
        parameter_size: '8B',
        quantization: 'Q4_K_M',
        size_bytes: 4_370_000_000,
        modalities_input: %w[text image],
        modalities_output: %w[text],
        metadata: { source: 'ollama' }
      )

      expect(info).to have_attributes(
        id: 'llama-3.1-8b',
        name: 'Llama 3.1 8B',
        provider: :ollama,
        instance: :worker_one,
        family: 'llama',
        context_length: 128_000,
        parameter_count: 8_000_000_000,
        parameter_size: '8B',
        quantization: 'Q4_K_M',
        size_bytes: 4_370_000_000
      )
      expect(info.capabilities).to eq(%i[completion vision tools])
      expect(info.modalities_input).to eq(%i[text image])
      expect(info.modalities_output).to eq([:text])
      expect(info.metadata).to eq({ source: 'ollama' })
    end

    it 'requires only id' do
      info = described_class.new(id: 'gpt-5')

      expect(info.id).to eq('gpt-5')
      expect(info.name).to eq('gpt-5')
      expect(info.provider).to eq(:'')
      expect(info.instance).to eq(:default)
      expect(info.family).to be_nil
      expect(info.capabilities).to eq([])
      expect(info.context_length).to be_nil
      expect(info.parameter_count).to be_nil
      expect(info.parameter_size).to be_nil
      expect(info.quantization).to be_nil
      expect(info.size_bytes).to be_nil
      expect(info.modalities_input).to eq([])
      expect(info.modalities_output).to eq([])
      expect(info.metadata).to eq({})
    end
  end

  describe 'normalization' do
    it 'strips whitespace from id and name' do
      info = described_class.new(id: '  gpt-5  ', name: '  GPT 5  ')
      expect(info.id).to eq('gpt-5')
      expect(info.name).to eq('GPT 5')
    end

    it 'converts provider to downcased symbol' do
      info = described_class.new(id: 'x', provider: 'Anthropic')
      expect(info.provider).to eq(:anthropic)
    end

    it 'converts instance to downcased symbol' do
      info = described_class.new(id: 'x', instance: 'Worker_Two')
      expect(info.instance).to eq(:worker_two)
    end

    it 'defaults instance to :default when nil' do
      info = described_class.new(id: 'x', instance: nil)
      expect(info.instance).to eq(:default)
    end

    it 'downcases and strips family' do
      info = described_class.new(id: 'x', family: '  Llama  ')
      expect(info.family).to eq('llama')
    end

    it 'normalizes capabilities to downcased symbols and deduplicates' do
      info = described_class.new(id: 'x', capabilities: ['Completion', :completion, 'VISION'])
      expect(info.capabilities).to eq(%i[completion vision])
    end

    it 'adds the canonical tools capability for function-calling aliases' do
      info = described_class.new(id: 'x', capabilities: %w[completion function_calling functions])

      expect(info.capabilities).to include(:completion, :function_calling, :functions, :tools)
      expect(info.tools?).to be true
      expect(info.supports?(:tools)).to be true
    end

    it 'converts context_length to integer' do
      info = described_class.new(id: 'x', context_length: '128000')
      expect(info.context_length).to eq(128_000)
    end

    it 'converts parameter_count to integer' do
      info = described_class.new(id: 'x', parameter_count: '8000000000')
      expect(info.parameter_count).to eq(8_000_000_000)
    end

    it 'converts size_bytes to integer' do
      info = described_class.new(id: 'x', size_bytes: '4370000000')
      expect(info.size_bytes).to eq(4_370_000_000)
    end

    it 'normalizes modalities to downcased symbols' do
      info = described_class.new(id: 'x', modalities_input: %w[Text IMAGE], modalities_output: ['Text'])
      expect(info.modalities_input).to eq(%i[text image])
      expect(info.modalities_output).to eq([:text])
    end

    it 'coerces non-hash metadata to empty hash' do
      info = described_class.new(id: 'x', metadata: 'invalid')
      expect(info.metadata).to eq({})
    end
  end

  describe 'capability predicates' do
    let(:info) do
      described_class.new(
        id: 'test',
        capabilities: %i[completion embedding vision tools thinking]
      )
    end

    it { expect(info.completion?).to be true }
    it { expect(info.embedding?).to be true }
    it { expect(info.vision?).to be true }
    it { expect(info.tools?).to be true }
    it { expect(info.thinking?).to be true }

    it 'returns false for missing capabilities' do
      minimal = described_class.new(id: 'test')
      expect(minimal.completion?).to be false
      expect(minimal.embedding?).to be false
      expect(minimal.vision?).to be false
      expect(minimal.tools?).to be false
      expect(minimal.thinking?).to be false
    end
  end

  describe '#to_h' do
    it 'returns a hash with all fields' do
      info = described_class.new(
        id: 'llama-3.1',
        provider: 'ollama',
        capabilities: [:completion],
        context_length: 128_000
      )
      hash = info.to_h

      expect(hash[:id]).to eq('llama-3.1')
      expect(hash[:provider]).to eq(:ollama)
      expect(hash[:capabilities]).to eq([:completion])
      expect(hash[:context_length]).to eq(128_000)
      expect(hash).to have_key(:metadata)
    end
  end

  describe 'value equality' do
    it 'considers two identical infos equal' do
      a = described_class.new(id: 'model-a', provider: 'ollama', capabilities: [:completion])
      b = described_class.new(id: 'model-a', provider: 'ollama', capabilities: [:completion])

      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it 'considers different infos not equal' do
      a = described_class.new(id: 'model-a', provider: 'ollama')
      b = described_class.new(id: 'model-b', provider: 'ollama')

      expect(a).not_to eq(b)
    end
  end

  describe 'immutability' do
    it 'is frozen' do
      info = described_class.new(id: 'test')
      expect(info).to be_frozen
    end
  end
end
