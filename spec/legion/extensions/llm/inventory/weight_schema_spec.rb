# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/weight_schema'

RSpec.describe 'Inventory::WeightSchema' do
  inventory = Legion::Extensions::Llm::Inventory

  let(:schema) { inventory.const_get(:WeightSchema) }
  let(:instance_key) do
    inventory::Identity::InstanceKey.new(provider_family: :vllm, instance_id: 'helios')
  end

  def operation_evidence(supported: %i[chat], **)
    Legion::Extensions::Llm::Taxonomies::OPERATIONS.to_h do |op|
      status, source = supported.include?(op) ? %i[supported provider_implementation] : %i[unknown absent]
      [op, Legion::Extensions::Llm::Inventory::OperationEvidence.new(operation: op, status: status, source: source)]
    end
  end

  def settings_for(provider: {})
    { extensions: { llm: { vllm: provider } }, llm: { routing: { tier_weights: { direct: 100 } } } }
  end

  # The offering-scope settings key is the lane's 5 tuple (operator-readable).
  def lane_id(tier: :direct, model: 'model-y', type: :inference)
    Legion::Extensions::Llm::Inventory::Identity.compose_lane_id(
      tier: tier, provider_family: 'vllm', instance_id: 'helios', type: type, model: model
    )
  end

  def inputs(settings, operation: :chat, model: 'model-y')
    schema.weight_inputs(
      settings: settings, instance_key: instance_key, model: model, tier: :direct,
      operation_evidence: operation_evidence(supported: [operation])
    )
  end

  it 'multiplies independent scopes without double-counting and lets offering override model' do
    settings = settings_for(
      provider: {
        weight: 100,
        models: { 'model-y' => { weight: 200 } },
        instances: { helios: { weight: 115 } },
        offerings: { lane_id => { weight: 300 } }
      }
    )

    result = inputs(settings)
    expect(result).to eq(tier: 100, provider: 100, instance: 115, model_or_offering: 300)
    expect(schema.base_weight(result)).to eq(345_000_000)
  end

  it 'uses provider model weight and lets instance model weight override it' do
    provider = { models: { 'model-y' => { weight: 200 } }, instances: { helios: {} } }
    expect(inputs(settings_for(provider: provider))[:model_or_offering]).to eq(200)

    provider[:instances][:helios][:models] = { 'model-y' => { weight: 250 } }
    expect(inputs(settings_for(provider: provider))[:model_or_offering]).to eq(250)
  end

  it 'preserves zero, rejects false, and defaults all missing axes to identity' do
    zero = inputs(settings_for(provider: { weight: 0, instances: { helios: {} } }))
    expect(zero[:provider]).to eq(0)
    expect(schema.base_weight(zero)).to eq(0)

    expect { inputs(settings_for(provider: { weight: false })) }
      .to raise_error(ArgumentError, /weight component/)

    identity = inputs(settings_for)
    expect(identity).to eq(tier: 100, provider: 100, instance: 100, model_or_offering: 100)
    expect(schema.base_weight(identity)).to eq(100_000_000)
  end

  it 'treats the offering scope as the lane 5 tuple: a different model key does not apply' do
    other_model_key = lane_id(model: 'other-model')
    settings = settings_for(
      provider: { offerings: { other_model_key => { weight: 999 }, lane_id => { weight: 321 } } }
    )

    expect(inputs(settings)[:model_or_offering]).to eq(321)
  end

  it 'derives the offering scope type from the operation: an embed key does not apply to a chat lane' do
    embed_key = lane_id(type: :embedding)
    settings = settings_for(provider: { offerings: { embed_key => { weight: 999 } } })

    expect(inputs(settings, operation: :embed)[:model_or_offering]).to eq(999)
    expect(inputs(settings)[:model_or_offering]).to eq(100) # chat draft: no inference key configured
  end

  it 'falls through to the model scope when no offering-scope key is configured' do
    settings = settings_for(provider: { models: { 'model-y' => { weight: 200 } } })
    expect(inputs(settings)[:model_or_offering]).to eq(200)
  end

  it 'raises when a multi-type draft has differing configured weights across its lanes' do
    inference_key = lane_id(type: :inference)
    embedding_key = lane_id(type: :embedding)
    settings = settings_for(
      provider: { offerings: { inference_key => { weight: 100 }, embedding_key => { weight: 200 } } }
    )
    expect do
      schema.weight_inputs(
        settings: settings, instance_key: instance_key, model: 'model-y', tier: :direct,
        operation_evidence: operation_evidence(supported: %i[chat embed])
      )
    end.to raise_error(ArgumentError, /ambiguous/)

    # Equal weights across the draft's lanes resolve to that weight.
    settings = settings_for(
      provider: { offerings: { inference_key => { weight: 100 }, embedding_key => { weight: 100 } } }
    )
    expect(
      schema.weight_inputs(
        settings: settings, instance_key: instance_key, model: 'model-y', tier: :direct,
        operation_evidence: operation_evidence(supported: %i[chat embed])
      )[:model_or_offering]
    ).to eq(100)
  end

  it 'rejects every present malformed configuration scope instead of defaulting it' do
    cases = {
      'extensions.llm' => { extensions: { llm: false } },
      'extensions.llm.vllm' => { extensions: { llm: { vllm: false } } },
      'provider.instances' => settings_for(provider: { instances: false }),
      'provider.instances.helios' => settings_for(provider: { instances: { helios: false } }),
      'llm.routing.tier_weights' => { extensions: { llm: {} }, llm: { routing: { tier_weights: false } } },
      'provider.offerings' => settings_for(provider: { offerings: false }),
      'provider.models.model-y' => settings_for(provider: { models: { 'model-y' => false } }),
      'instance.models.model-y' => settings_for(
        provider: { instances: { helios: { models: { 'model-y' => false } } } }
      )
    }

    cases.each do |path, settings|
      expect { inputs(settings) }.to raise_error(ArgumentError, /#{Regexp.escape(path)}/)
    end
  end
end
