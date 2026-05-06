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

    expect(defaults.dig(:fleet, :consumer, :scheduler)).to eq(:basic_get)
    expect(defaults.dig(:fleet, :consumer, :queue_expires_ms)).to eq(60_000)
    expect(defaults.dig(:fleet, :consumer, :consumer_ack_timeout_ms)).to eq(90_000)
    expect(defaults.dig(:fleet, :auth, :accepted_issuers)).to eq(['legion-llm'])
    expect(defaults.dig(:fleet, :auth, :audience)).to eq('lex-llm-fleet-worker')
    expect(defaults.dig(:fleet, :auth, :algorithm)).to eq('HS256')
    expect(defaults.dig(:fleet, :auth, :replay_ttl_seconds)).to eq(600)
    expect(defaults.dig(:fleet, :responder, :require_idempotency)).to be(true)
    expect(defaults.dig(:fleet, :responder, :idempotency_ttl_seconds)).to eq(600)
  end

  it 'reads fleet settings from extension settings before falling back to core llm settings' do
    data = {
      extensions: { llm: { fleet: { auth: { accepted_issuers: ['extension'] } } } },
      llm: {
        fleet: {
          auth: { audience: 'core-audience', accepted_issuers: ['core'] },
          responder: { require_auth: false }
        }
      }
    }
    settings = Module.new
    settings.define_singleton_method(:[]) { |key| data[key] }

    stub_const('Legion::Settings', settings)

    expect(Legion::Extensions::Llm::Fleet::Settings.value(:fleet, :auth, :accepted_issuers, default: []))
      .to eq(['extension'])
    expect(Legion::Extensions::Llm::Fleet::Settings.value(:fleet, :auth, :audience, default: nil))
      .to eq('core-audience')
    expect(Legion::Extensions::Llm::Fleet::Settings.value(:fleet, :responder, :require_auth, default: true))
      .to be(false)
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
    expect(settings.dig(:fleet, :consumer, :scheduler)).to eq(:basic_get)
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
