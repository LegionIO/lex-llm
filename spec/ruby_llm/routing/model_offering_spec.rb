# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Routing::ModelOffering do
  subject(:offering) do
    described_class.new(
      provider_family: :ollama,
      instance_id: :'macbook-m4-max',
      transport: :rabbitmq,
      model: 'qwen3.6:27b-q4_K_M',
      capabilities: %i[chat tools thinking],
      limits: { context_window: 32_768, max_output_tokens: 8192 },
      policy_tags: %i[phi_allowed internal_only]
    )
  end

  it 'normalizes provider-neutral offering metadata' do
    expect(offering).to have_attributes(
      provider_family: :ollama,
      instance_id: :'macbook-m4-max',
      transport: :rabbitmq,
      tier: :fleet,
      model: 'qwen3.6:27b-q4_K_M',
      usage_type: :inference
    )
    expect(offering.capabilities).to eq(%i[chat tools thinking])
    expect(offering.context_window).to eq(32_768)
  end

  it 'checks route eligibility without provider-specific code' do
    expect(
      offering.eligible_for?(
        usage_type: :inference,
        required_capabilities: %i[tools thinking],
        min_context_window: 32_000,
        policy_tags: [:phi_allowed]
      )
    ).to be true

    expect(offering.eligible_for?(min_context_window: 65_536)).to be false
    expect(offering.eligible_for?(required_capabilities: [:vision])).to be false
  end

  it 'treats disabled offerings as ineligible' do
    disabled = described_class.new(
      provider_family: :ollama,
      instance_id: :local,
      model: 'qwen',
      metadata: { enabled: false }
    )

    expect(disabled).not_to be_enabled
    expect(disabled.eligible_for?).to be false
  end

  it 'generates clean fleet inference lane keys with context windows' do
    expect(offering.lane_key).to eq('llm.fleet.inference.qwen3-6-27b-q4-k-m.ctx32768')
  end

  it 'generates embedding lanes without context suffixes' do
    embedding = described_class.new(
      provider_family: :ollama,
      instance_id: :'gpu-01',
      transport: :rabbitmq,
      model: 'nomic-embed-text:latest',
      usage_type: :embed,
      capabilities: [:embedding]
    )

    expect(embedding).to be_embedding
    expect(embedding.lane_key).to eq('llm.fleet.embed.nomic-embed-text-latest')
  end

  it 'can include an eligibility fingerprint when lanes need stricter matching' do
    key = offering.lane_key(include_fingerprint: true)

    expect(key).to match(/\Allm\.fleet\.inference\.qwen3-6-27b-q4-k-m\.ctx32768\.elig\.[0-9a-f]{10}\z/)
    expect(offering.eligibility_fingerprint).to eq(key.split('.').last)
  end

  it 'normalizes string numeric limits from JSON-backed settings' do
    string_limits = described_class.new(
      provider_family: :ollama,
      model: 'qwen',
      limits: { context_window: '32768', max_output_tokens: '8192' }
    )

    expect(string_limits.context_window).to eq(32_768)
    expect(string_limits.max_output_tokens).to eq(8192)
    expect(string_limits.eligible_for?(min_context_window: 32_000)).to be true
  end

  it 'normalizes string-keyed JSON-backed offering fields' do
    json_offering = described_class.new(
      'provider_family' => 'ollama',
      'instance_id' => 'macbook-m4-max',
      'transport' => 'rabbitmq',
      'model' => 'nomic-embed-text',
      'type' => 'embed',
      'capabilities' => %w[embedding],
      'limits' => { 'context_window' => '8192' },
      'metadata' => { 'enabled' => true }
    )

    expect(json_offering.provider_family).to eq(:ollama)
    expect(json_offering.instance_id).to eq(:'macbook-m4-max')
    expect(json_offering.transport).to eq(:rabbitmq)
    expect(json_offering.usage_type).to eq(:embedding)
    expect(json_offering.context_window).to eq(8192)
    expect(json_offering).to be_enabled
  end

  it 'treats string-keyed disabled metadata as ineligible' do
    disabled = described_class.new(
      'provider_family' => 'ollama',
      'model' => 'qwen',
      'metadata' => { 'enabled' => false }
    )

    expect(disabled).not_to be_enabled
    expect(disabled.eligible_for?).to be false
  end

  it 'keeps sensitive metadata out of eligibility fingerprints' do
    safe = described_class.new(
      provider_family: :ollama,
      model: 'qwen',
      metadata: { eligibility: { endpoint_url: 'http://gpu.internal', network_boundary: :corp_lan } }
    )
    changed_secret = described_class.new(
      provider_family: :ollama,
      model: 'qwen',
      metadata: { eligibility: { endpoint_url: 'http://other.internal', network_boundary: :corp_lan } }
    )

    expect(safe.eligibility_fingerprint).to eq(changed_secret.eligibility_fingerprint)
  end

  it 'serializes the normalized shape used by routers and registries' do
    expect(offering.to_h).to include(
      provider_family: :ollama,
      instance_id: :'macbook-m4-max',
      tier: :fleet,
      usage_type: :inference,
      limits: { context_window: 32_768, max_output_tokens: 8192 }
    )
  end
end
