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

  def settings_for(provider: {})
    { extensions: { llm: { vllm: provider } }, llm: { routing: { tier_weights: { direct: 100 } } } }
  end

  def inputs(settings, native: 'deployment-x', model: 'model-y')
    schema.weight_inputs(
      settings: settings, instance_key: instance_key,
      provider_native_key: native, model: model, tier: :direct
    )
  end

  it 'multiplies independent scopes without double-counting and lets offering override model' do
    offering_id = inventory::Identity.offering_id(instance_key: instance_key, provider_native_key: 'deployment-x')
    settings = settings_for(
      provider: {
        weight: 100,
        models: { 'model-y' => { weight: 200 } },
        instances: { helios: { weight: 115 } },
        offerings: { offering_id => { weight: 300 } }
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

  it 'derives offering identity from the provider-native key rather than the model' do
    deployment_id = inventory::Identity.offering_id(
      instance_key: instance_key, provider_native_key: 'deployment-x'
    )
    model_id = inventory::Identity.offering_id(instance_key: instance_key, provider_native_key: 'model-y')
    settings = settings_for(provider: { offerings: { deployment_id => { weight: 321 }, model_id => { weight: 999 } } })

    expect(inputs(settings)[:model_or_offering]).to eq(321)
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
