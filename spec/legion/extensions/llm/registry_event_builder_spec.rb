# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::RegistryEventBuilder do
  subject(:builder) { described_class.new(provider_family: :ollama) }

  describe '#provider_family' do
    it 'normalizes to a downcased symbol' do
      b = described_class.new(provider_family: 'Anthropic')
      expect(b.provider_family).to eq(:anthropic)
    end
  end

  describe '#model_available' do
    let(:model) do
      Legion::Extensions::Llm::Model::Info.from_hash(
        id: 'llama-3.1-8b',
        name: 'Llama 3.1 8B',
        provider: 'ollama',
        capabilities: %w[completion streaming],
        modalities: { input: %w[text], output: %w[text] },
        context_window: 128_000,
        max_output_tokens: 8192
      )
    end

    let(:readiness) { { ready: true, configured: true } }

    it 'builds a RegistryEvent with offering data' do
      event = builder.model_available(model, readiness: readiness)
      expect(event).to be_a(Legion::Extensions::Llm::Routing::RegistryEvent)
      expect(event.event_type).to eq(:offering_available)
      expect(event.offering.model).to eq('llama-3.1-8b')
      expect(event.offering.provider_family).to eq(:ollama)
    end

    it 'includes model health from readiness' do
      event = builder.model_available(model, readiness: readiness)
      expect(event.health[:ready]).to be true
      expect(event.health[:status]).to eq(:available)
    end

    it 'includes extension metadata' do
      event = builder.model_available(model, readiness: readiness)
      expect(event.metadata[:extension]).to eq(:llm_ollama)
      expect(event.metadata[:provider]).to eq(:ollama)
    end
  end

  describe '#readiness' do
    it 'builds an available event when ready' do
      event = builder.readiness({ ready: true, configured: true })
      expect(event.event_type).to eq(:offering_available)
    end

    it 'builds an unavailable event when not ready' do
      event = builder.readiness({ ready: false, configured: true })
      expect(event.event_type).to eq(:offering_unavailable)
    end

    it 'preserves error details from health' do
      event = builder.readiness({ ready: false, health: { error: 'ConnectionRefused', message: 'refused' } })
      expect(event.health[:error_class]).to eq('ConnectionRefused')
      expect(event.health[:error]).to eq('refused')
    end
  end
end
