# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

RSpec.describe Legion::Extensions::Llm::Models do
  subject(:models) { described_class.new([chat_model, embedding_model]) }

  include_context 'with fake llm provider'

  let(:chat_model) do
    Legion::Extensions::Llm::Model::Info.new(
      id: 'fake-chat-model',
      name: 'Fake Chat Model',
      provider: 'fake_llm',
      family: 'fake',
      modalities: { input: ['text'], output: ['text'] },
      capabilities: %w[function_calling structured_output streaming]
    )
  end

  let(:embedding_model) do
    Legion::Extensions::Llm::Model::Info.new(
      id: 'fake-embedding-model',
      name: 'Fake Embedding Model',
      provider: 'fake_llm',
      family: 'fake',
      modalities: { input: ['text'], output: ['embeddings'] },
      capabilities: ['embedding']
    )
  end

  after do
    described_class.instance_variable_set(:@instance, nil)
  end

  it 'filters models by provider and usage type' do
    expect(models.by_provider(:fake_llm).map(&:id)).to eq(%w[fake-chat-model fake-embedding-model])
    expect(models.chat_models.map(&:id)).to eq(['fake-chat-model'])
    expect(models.embedding_models.map(&:id)).to eq(['fake-embedding-model'])
  end

  it 'resolves models through the provider registry' do
    allow(described_class).to receive(:instance).and_return(models)

    model, provider = described_class.resolve('fake-chat-model')

    expect(model.id).to eq('fake-chat-model')
    expect(provider).to be_a(SpecSupport::FakeLLMProvider)
  end

  it 'supports provider-specific model id normalization through provider hooks' do
    provider = Class.new(SpecSupport::FakeLLMProvider) do
      def self.resolve_model_id(model_id, config: nil) # rubocop:disable Lint/UnusedMethodArgument
        model_id == 'alias-model' ? 'fake-chat-model' : model_id
      end
    end
    Legion::Extensions::Llm::Provider.register(:normalizing_fake, provider)
    normalized = Legion::Extensions::Llm::Model::Info.new(
      id: 'fake-chat-model',
      name: 'Normalized',
      provider: 'normalizing_fake',
      modalities: { output: ['text'] }
    )
    registry = described_class.new([normalized])

    expect(registry.find('alias-model', :normalizing_fake).id).to eq('fake-chat-model')
  end

  it 'raises when a model exists but its provider extension is not registered' do
    registry = described_class.new([
                                     Legion::Extensions::Llm::Model::Info.new(
                                       id: 'orphan-model',
                                       name: 'Orphan',
                                       provider: 'missing_provider'
                                     )
                                   ])
    allow(described_class).to receive(:instance).and_return(registry)

    expect do
      described_class.resolve('orphan-model')
    end.to raise_error(Legion::Extensions::Llm::Error, /Unknown provider/)
  end

  it 'saves and loads model metadata as Legion JSON' do
    temp_file = Tempfile.new(['models', '.json'])
    models.save_to_json(temp_file.path)

    parsed = Legion::JSON.parse(File.read(temp_file.path), symbolize_names: false)
    expect(parsed.map { |model| model['id'] }).to eq(%w[fake-chat-model fake-embedding-model])

    loaded = described_class.read_from_json(temp_file.path)
    expect(loaded.map(&:id)).to eq(%w[fake-chat-model fake-embedding-model])
  ensure
    temp_file&.close!
  end
end
