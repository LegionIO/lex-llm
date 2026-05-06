# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::ProviderSettings do
  it 'rejects top-level fleet settings for provider defaults' do
    expect do
      described_class.build(family: :ollama, fleet: { enabled: true })
    end.to raise_error(ArgumentError, /fleet.*instance/i)
  end

  it 'rejects legacy gateway settings' do
    expect do
      described_class.build(family: :openai, gateways: [])
    end.to raise_error(ArgumentError, /gateways/i)
  end

  it 'keeps fleet settings under the default provider instance' do
    settings = described_class.build(
      family: :ollama,
      instance: {
        endpoint: 'http://127.0.0.1:11434',
        fleet: { enabled: false, respond_to_requests: false, capabilities: %i[chat embed] }
      }
    )

    expect(settings.dig(:instances, :default, :fleet, :respond_to_requests)).to be(false)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('http://127.0.0.1:11434')
  end
end
