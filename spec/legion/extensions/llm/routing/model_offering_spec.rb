# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Routing::ModelOffering do
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
      offering_id: 'ollama:macbook-m4-max:inference:qwen3-6-27b-q4-k-m',
      provider_family: :ollama,
      provider_instance: :'macbook-m4-max',
      instance_id: :'macbook-m4-max',
      transport: :rabbitmq,
      tier: :fleet,
      model: 'qwen3.6:27b-q4_K_M',
      canonical_model_alias: 'qwen3.6:27b-q4_K_M',
      usage_type: :inference
    )
    expect(offering.capabilities).to eq(%i[chat tools thinking])
    expect(offering.context_window).to eq(32_768)
  end

  it 'accepts expanded contract fields while preserving instance_id compatibility' do
    expanded = described_class.new(
      offering_id: 'azure:gpt4o-prod',
      provider_family: :azure_foundry,
      model_family: :openai,
      provider_instance: :eastus,
      model: 'gpt4o-prod',
      canonical_model_alias: 'gpt-4o',
      routing_metadata: { region: 'eastus', deployment: 'gpt4o-prod' },
      capabilities: %i[chat tools]
    )

    expect(expanded).to have_attributes(
      offering_id: 'azure:gpt4o-prod',
      provider_family: :azure_foundry,
      model_family: :openai,
      provider_instance: :eastus,
      instance_id: :eastus,
      model: 'gpt4o-prod',
      canonical_model_alias: 'gpt-4o',
      routing_metadata: { region: 'eastus', deployment: 'gpt4o-prod' }
    )
    expect(expanded.to_h).to include(
      provider_instance: :eastus,
      instance_id: :eastus,
      canonical_model_alias: 'gpt-4o',
      routing_metadata: { region: 'eastus', deployment: 'gpt4o-prod' }
    )
  end

  it 'lifts model family and aliases from legacy metadata' do
    legacy = described_class.new(
      provider_family: :bedrock,
      instance_id: :'us-east-1',
      model: 'anthropic.claude-3-haiku-20240307-v1:0',
      metadata: { model_family: :anthropic, alias: 'claude-3-haiku' }
    )

    expect(legacy.model_family).to eq(:anthropic)
    expect(legacy.canonical_model_alias).to eq('claude-3-haiku')
    expect(legacy.model_alias?('claude-3-haiku')).to be true
    expect(legacy.model_alias?('anthropic.claude-3-haiku-20240307-v1:0')).to be true
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

  it 'treats legacy function-calling capability names as tools support' do
    legacy_tools = described_class.new(
      provider_family: :vllm,
      model: 'qwen-tools',
      capabilities: %i[chat function_calling]
    )

    expect(legacy_tools.capabilities).to include(:function_calling, :tools)
    expect(legacy_tools.eligible_for?(required_capabilities: [:tools])).to be true
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

  it 'uses canonical model aliases for fleet lanes when provider deployments hide the base model' do
    deployment = described_class.new(
      provider_family: :azure_foundry,
      provider_instance: :default,
      model: 'gpt4o-prod',
      canonical_model_alias: 'gpt-4o',
      limits: { context_window: 128_000 }
    )

    expect(deployment.lane_key).to eq('llm.fleet.inference.gpt-4o.ctx128000')
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
      offering_id: 'ollama:macbook-m4-max:inference:qwen3-6-27b-q4-k-m',
      provider_family: :ollama,
      provider_instance: :'macbook-m4-max',
      instance_id: :'macbook-m4-max',
      tier: :fleet,
      canonical_model_alias: 'qwen3.6:27b-q4_K_M',
      usage_type: :inference,
      limits: { context_window: 32_768, max_output_tokens: 8192 }
    )
  end
end
