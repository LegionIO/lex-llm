# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm do
  include_context 'with fake llm provider'

  it 'loads and discovers provider classes from the namespace' do
    provider_classes = Legion::Extensions::Llm::Models.scan_provider_classes
    expect(provider_classes).to include(fake_llm: SpecSupport::FakeLLMProvider)
  end

  describe 'provider funnel contract (0.8.0)' do
    let(:provider) do
      SpecSupport::FakeLLMProvider.new(
        Legion::Extensions::Llm::Configuration.new.tap do |config|
          config.fake_llm_api_key = 'fake-key'
        end
      )
    end

    let(:user_message) do
      Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    end

    it 'completes with canonical input and returns a Canonical::Response' do
      response = provider.complete([user_message], model: 'fake-chat-model')
      expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
      expect(response.text).to eq('fake response to hello')
      expect(response.usage).to be_a(Legion::Extensions::Llm::Canonical::Usage)
    end

    it 'streams canonical chunks ending in exactly one done chunk (05 O5)' do
      chunks = []
      provider.complete([user_message], model: 'fake-chat-model') { |chunk| chunks << chunk }

      expect(chunks).to all(be_a(Legion::Extensions::Llm::Canonical::Chunk))
      expect(chunks.count(&:done?)).to eq(1)
      expect(chunks.last).to be_done
      expect(chunks.filter_map(&:delta).join).to eq('streamed response')
    end

    it 'rejects non-canonical messages at the boundary with a typed ArgumentError (08 F2)' do
      expect { provider.complete([{ role: 'user', content: 'hash' }], model: 'fake-chat-model') }
        .to raise_error(ArgumentError, /Canonical::Message/)
      expect { provider.complete([nil], model: 'fake-chat-model') }
        .to raise_error(ArgumentError, /Canonical::Message/)
      expect { provider.complete(['string'], model: 'fake-chat-model') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it 'keeps the canonical conversation operations on the base' do
      expect(provider).to respond_to(:chat)
      expect(provider).to respond_to(:stream_chat)
      expect(provider).to respond_to(:count_tokens)
      expect(provider).to respond_to(:list_models)
      expect(provider).to respond_to(:discover_offerings)
      expect(provider).to respond_to(:health)
      expect(provider).to respond_to(:embed)
      expect(provider).to respond_to(:moderate)
      expect(provider).to respond_to(:image)
      expect(provider).to respond_to(:transcribe)
    end

    it 'serves discover_offerings from the registry snapshot (07 C5)' do
      expect(provider.discover_offerings).to eq([])
    end

    it 'counts tokens for canonical messages' do
      expect(provider.count_tokens(messages: [user_message], model: 'fake-chat-model')).to be_a(Integer)
    end
  end
end
