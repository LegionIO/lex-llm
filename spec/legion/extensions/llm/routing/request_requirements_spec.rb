# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/routing/request_requirements'

RSpec.describe Legion::Extensions::Llm::Routing::RequestRequirements do
  let(:validation_error) { Legion::Extensions::Llm::Inventory::Errors::ValidationError }
  let(:attributes) do
    {
      operation: :chat, required_capabilities: %i[completion vision], input_bound: 0,
      required_output_tokens: 0, context_budget: 0, requested_embedding_dimensions: nil,
      modality: nil, provider_pin: nil, instance_pin: nil, model_pin: nil, tier_pin: nil,
      body_model_hint_decision: Legion::Extensions::Llm::Routing::BodyModelHintDecision.new(
        requested_model: nil, disposition: :absent, settings_generation: 0
      ),
      routing_seed: '0123456789abcdef0123456789abcdef', maximum_attempts: 1
    }
  end

  it 'isolates routing facts from later mutations of request-owned values' do
    capabilities = %i[completion vision]
    modality = { output: [+ 'image', { format: + 'png' }] }
    model = + 'model-a'
    instance = + 'primary'
    seed = attributes[:routing_seed].dup
    requirements = described_class.new(**attributes, required_capabilities: capabilities, modality: modality,
                                                     model_pin: model, instance_pin: instance, routing_seed: seed)

    capabilities.clear
    modality[:output].first.replace('audio')
    modality[:output].last[:format].replace('wav')
    model.replace('other-model')
    instance.replace('other-instance')
    seed.replace('f' * 32)

    expect(requirements.required_capabilities).to eq(%i[completion vision])
    expect(requirements.modality).to eq(output: ['image', { format: 'png' }])
    expect(requirements.model_pin).to eq('model-a')
    expect(requirements.instance_pin).to eq('primary')
    expect(requirements.routing_seed).to eq(attributes[:routing_seed])
    expect { requirements.modality[:output].last[:format].replace('jpeg') }.to raise_error(FrozenError)
    expect { requirements.required_capabilities.clear }.to raise_error(FrozenError)
  end

  it 'rejects untranslated vocabulary and incorrectly typed explicit pins' do
    {
      operation: :completion, required_capabilities: [:function_calling], tier_pin: 'local',
      provider_pin: 'openai', instance_pin: :primary, model_pin: :model
    }.each do |field, value|
      expect { described_class.new(**attributes, field => value) }.to raise_error(validation_error, /#{field}/)
    end
  end

  it 'rejects invalid budgets, dimensions, and attempt limits rather than coercing them' do
    {
      input_bound: -1, required_output_tokens: 1.5, context_budget: nil,
      requested_embedding_dimensions: 0, maximum_attempts: 0
    }.each do |field, value|
      expect { described_class.new(**attributes, field => value) }.to raise_error(validation_error, /#{field}/)
    end
  end

  it 'requires request ownership of the routing seed and model hint decision' do
    expect { described_class.new(**attributes.except(:routing_seed)) }.to raise_error(ArgumentError, /routing_seed/)
    expect { described_class.new(**attributes, routing_seed: 'A' * 32) }.to raise_error(validation_error, /routing_seed/)
    expect { described_class.new(**attributes, body_model_hint_decision: attributes[:body_model_hint_decision].to_h) }
      .to raise_error(validation_error, /body_model_hint_decision/)
  end

  it 'rejects unsupported mutable values embedded in modality' do
    expect { described_class.new(**attributes, modality: { image: Object.new }) }
      .to raise_error(validation_error, /modality.image/)
  end
end
