# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LexLLM::Models do
  include_context 'with configured LexLLM'
  before do
    skip 'Local provider specs disabled via SKIP_LOCAL_PROVIDER_TESTS' if ENV['SKIP_LOCAL_PROVIDER_TESTS']
  end

  describe 'local provider model fetching' do
    describe '.refresh!' do
      context 'with default parameters' do # rubocop:disable RSpec/NestedGroups
        it 'includes local providers' do
          allow(described_class).to receive(:fetch_models_dev_models).and_return({ models: [], fetched: true })
          allow(LexLLM::Provider).to receive_messages(providers: {}, configured_providers: [])

          described_class.refresh!

          expect(LexLLM::Provider).to have_received(:configured_providers)
        end
      end

      context 'with remote_only: true' do # rubocop:disable RSpec/NestedGroups
        it 'excludes local providers' do
          allow(described_class).to receive(:fetch_models_dev_models).and_return({ models: [], fetched: true })
          allow(LexLLM::Provider).to receive_messages(remote_providers: {}, configured_remote_providers: [])

          described_class.refresh!(remote_only: true)

          expect(LexLLM::Provider).to have_received(:configured_remote_providers)
        end
      end
    end

    describe '.fetch_from_providers' do
      it 'defaults to remote_only: true' do
        allow(LexLLM::Provider).to receive_messages(remote_providers: {}, configured_remote_providers: [])

        described_class.fetch_from_providers

        expect(LexLLM::Provider).to have_received(:configured_remote_providers)
      end

      it 'can include local providers with remote_only: false' do
        allow(LexLLM::Provider).to receive_messages(providers: {}, configured_providers: [])

        described_class.fetch_from_providers(remote_only: false)

        expect(LexLLM::Provider).to have_received(:configured_providers)
      end
    end

    describe 'Ollama models integration' do
      let(:ollama) { LexLLM::Providers::Ollama.new(LexLLM.config) }

      it 'responds to list_models' do
        expect(ollama).to respond_to(:list_models)
      end

      it 'can parse list models response' do
        response = double( # rubocop:disable RSpec/VerifiedDoubles
          'Response',
          body: {
            'data' => [
              {
                'id' => 'llama3:latest',
                'created' => 1_234_567_890,
                'owned_by' => 'library'
              }
            ]
          }
        )

        models = ollama.parse_list_models_response(response, 'ollama', nil)
        expect(models).to be_an(Array)
        expect(models.first).to be_a(LexLLM::Model::Info)
        expect(models.first.id).to eq('llama3:latest')
        expect(models.first.provider).to eq('ollama')
        expect(models.first.capabilities).to include('streaming', 'function_calling', 'vision')
      end
    end

    describe 'GPUStack models integration' do
      let(:gpustack) { LexLLM::Providers::GPUStack.new(LexLLM.config) }

      it 'responds to list_models' do
        expect(gpustack).to respond_to(:list_models)
      end
    end

    describe 'local provider model resolution' do
      it 'assumes model exists for Ollama without warning after refresh' do
        allow(described_class).to receive_messages(fetch_provider_models: {
                                                     models: [],
                                                     fetched_providers: [],
                                                     configured_names: [],
                                                     failed: []
                                                   }, fetch_models_dev_models: { models: [], fetched: true })

        allow_any_instance_of(LexLLM::Providers::Ollama).to( # rubocop:disable RSpec/AnyInstance
          receive(:list_models).and_return([
                                             LexLLM::Model::Info.new(
                                               id: 'test-model',
                                               provider: 'ollama',
                                               name: 'Test Model',
                                               capabilities: %w[streaming
                                                                function_calling]
                                             )
                                           ])
        )
        allow(LexLLM.logger).to receive(:warn)

        described_class.refresh!

        chat = LexLLM.chat(provider: :ollama, model: 'test-model')
        expect(chat.model.id).to eq('test-model')
        expect(LexLLM.logger).not_to have_received(:warn)
      end

      it 'assumes model exists for GPUStack without checking registry' do
        chat = LexLLM.chat(provider: :gpustack, model: 'any-model')
        expect(chat.model.id).to eq('any-model')
        expect(chat.model.provider).to eq('gpustack')
      end
    end
  end
end
