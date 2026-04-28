# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Routing::RegistryEvent do
  subject(:event) do
    described_class.new(
      event_id: 'evt-123',
      event_type: :offering_available,
      occurred_at: Time.utc(2026, 4, 28, 14, 30, 15, 123_456),
      offering: offering,
      runtime: { host_id: 'macbook-m4-max', process: { pid: 12_345 } },
      capacity: { concurrency: 4, queued: 0 },
      health: { ready: true, latency_ms: 180 },
      lane: 'llm.fleet.inference.qwen3-6.ctx32768',
      metadata: { observed_by: :lex_llm_ollama }
    )
  end

  let(:offering) do
    Legion::Extensions::Llm::Routing::ModelOffering.new(
      provider_family: :ollama,
      provider_instance: :'macbook-m4-max',
      transport: :rabbitmq,
      model: 'qwen3.6',
      capabilities: %i[chat tools],
      limits: { context_window: 32_768 },
      credentials: { api_key: 'secret' },
      metadata: { enabled: true, api_key: 'secret' }
    )
  end

  it 'serializes a provider-neutral registry envelope' do
    expect(event).to have_attributes(
      event_id: 'evt-123',
      event_type: :offering_available,
      occurred_at: Time.utc(2026, 4, 28, 14, 30, 15, 123_456)
    )

    expect(event.to_h).to include(
      event_id: 'evt-123',
      event_type: :offering_available,
      occurred_at: '2026-04-28T14:30:15.123456Z',
      runtime: { host_id: 'macbook-m4-max', process: { pid: 12_345 } },
      capacity: { concurrency: 4, queued: 0 },
      health: { ready: true, latency_ms: 180 },
      lane: 'llm.fleet.inference.qwen3-6.ctx32768',
      metadata: { observed_by: :lex_llm_ollama }
    )
    expect(event.to_h[:offering]).to include(
      offering_id: 'ollama:macbook-m4-max:inference:qwen3-6',
      provider_family: :ollama,
      provider_instance: :'macbook-m4-max',
      model: 'qwen3.6',
      capabilities: %i[chat tools],
      limits: { context_window: 32_768 },
      metadata: { enabled: true }
    )
  end

  it 'omits sensitive offering fields before publishing' do
    envelope = event.to_h

    expect(envelope[:offering]).not_to have_key(:credentials)
    expect(envelope[:offering][:metadata]).not_to have_key(:api_key)
  end

  it 'normalizes hash offerings through ModelOffering' do
    event = described_class.heartbeat(
      {
        'provider_family' => 'bedrock',
        'provider_instance' => 'us-east-1',
        'model' => 'amazon.titan-embed-text-v2:0',
        'usage_type' => 'embedding',
        'capabilities' => ['embedding']
      },
      event_id: 'evt-heartbeat',
      occurred_at: '2026-04-28T14:31:00Z'
    )

    expect(event.to_h).to include(
      event_id: 'evt-heartbeat',
      event_type: :offering_heartbeat,
      occurred_at: '2026-04-28T14:31:00.000000Z'
    )
    expect(event.to_h[:offering]).to include(
      provider_family: :bedrock,
      provider_instance: :'us-east-1',
      usage_type: :embedding,
      capabilities: [:embedding]
    )
  end

  it 'provides event-type helpers' do
    expect(described_class.available(offering).event_type).to eq(:offering_available)
    expect(described_class.unavailable(offering).event_type).to eq(:offering_unavailable)
    expect(described_class.degraded(offering).event_type).to eq(:offering_degraded)
    expect(described_class.heartbeat(offering).event_type).to eq(:offering_heartbeat)
  end

  it 'rejects unknown event types' do
    expect do
      described_class.new(event_type: :available, offering: offering)
    end.to raise_error(ArgumentError, /unsupported registry event type/)
  end

  it 'rejects sensitive runtime, capacity, health, lane, and metadata keys' do
    %i[runtime capacity health lane metadata].each do |field|
      attributes = {
        event_type: :offering_degraded,
        offering: offering,
        field => { 'nested' => { 'api_key' => 'secret' } }
      }

      expect do
        described_class.new(**attributes)
      end.to raise_error(ArgumentError, /#{field} contains sensitive key: nested.api_key/)
    end
  end
end
