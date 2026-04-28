# frozen_string_literal: true

require 'legion/extensions/llm'

RSpec.describe Legion::Extensions::Llm do
  it 'exposes the Legion-native extension namespace for autoloading' do
    expect(described_class::Types::ModelOffering).to equal(Legion::Extensions::Llm::Routing::ModelOffering)
    expect(described_class::Types::OfferingRegistry).to equal(Legion::Extensions::Llm::Routing::OfferingRegistry)
    expect(described_class::Routing::LaneKey).to equal(Legion::Extensions::Llm::Routing::LaneKey)
    expect(described_class::Routing::OfferingRegistry).to equal(Legion::Extensions::Llm::Routing::OfferingRegistry)
  end

  it 'provides complete default fleet settings' do
    defaults = described_class.default_settings

    expect(defaults.dig(:fleet, :scheduler)).to eq(:basic_get)
    expect(defaults.dig(:fleet, :queue_expires_ms)).to eq(60_000)
    expect(defaults.dig(:fleet, :endpoint, :accept_when)).to eq([])
  end

  it 'builds provider defaults with shared fleet settings' do
    settings = described_class.provider_settings(
      family: :ollama,
      instance: {
        base_url: 'http://localhost:11434',
        fleet: { enabled: true, consumer_priority: 10 }
      }
    )

    expect(settings[:provider_family]).to eq(:ollama)
    expect(settings.dig(:discovery, :interval_seconds)).to eq(300)
    expect(settings.dig(:fleet, :scheduler)).to eq(:basic_get)
    expect(settings.dig(:instances, :default, :base_url)).to eq('http://localhost:11434')
    expect(settings.dig(:instances, :default, :fleet)).to include(
      enabled: true,
      consumer_priority: 10,
      prefetch: 1
    )
  end

  it 'deep duplicates provider defaults between calls' do
    first = described_class.provider_settings(family: :vllm)
    second = described_class.provider_settings(family: :vllm)

    first.dig(:instances, :default, :fleet)[:prefetch] = 99

    expect(second.dig(:instances, :default, :fleet, :prefetch)).to eq(1)
  end
end
