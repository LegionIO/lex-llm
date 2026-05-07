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

  describe '.infer_tier_from_endpoint' do
    subject(:infer) { described_class.infer_tier_from_endpoint(url) }

    context 'with localhost' do
      let(:url) { 'http://localhost:11434' }

      it { is_expected.to eq(:local) }
    end

    context 'with 127.0.0.1' do
      let(:url) { 'http://127.0.0.1:8080/v1' }

      it { is_expected.to eq(:local) }
    end

    context 'with ::1 (IPv6 loopback)' do
      let(:url) { 'http://[::1]:8080' }

      it { is_expected.to eq(:local) }
    end

    context 'with a non-loopback IP' do
      let(:url) { 'http://10.0.0.1:8080' }

      it { is_expected.to eq(:direct) }
    end

    context 'with a named remote host' do
      let(:url) { 'https://apollo.internal/v1' }

      it { is_expected.to eq(:direct) }
    end

    context 'with nil' do
      let(:url) { nil }

      it { is_expected.to eq(:direct) }
    end

    context 'with an invalid URI' do
      let(:url) { 'not a uri :::' }

      it { is_expected.to eq(:direct) }
    end
  end
end
