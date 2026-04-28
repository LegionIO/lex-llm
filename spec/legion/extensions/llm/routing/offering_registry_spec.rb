# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Routing::OfferingRegistry do
  subject(:registry) { described_class.new([chat, embedding]) }

  let(:chat) do
    Legion::Extensions::Llm::Routing::ModelOffering.new(
      provider_family: :azure_foundry,
      model_family: :openai,
      provider_instance: :eastus,
      model: 'gpt4o-prod',
      canonical_model_alias: 'gpt-4o',
      capabilities: %i[chat tools],
      limits: { context_window: 128_000 }
    )
  end

  let(:embedding) do
    Legion::Extensions::Llm::Routing::ModelOffering.new(
      provider_family: :bedrock,
      model_family: :amazon,
      instance_id: :'us-east-1',
      model: 'amazon.titan-embed-text-v2:0',
      canonical_model_alias: 'titan-embed-text-v2',
      usage_type: :embedding,
      capabilities: [:embedding]
    )
  end

  it 'registers hashes and offerings by normalized offering_id' do
    replacement = registry.register(
      chat.to_h.merge(capabilities: %i[chat vision])
    )

    expect(registry.find(chat.offering_id)).to eq(replacement)
    expect(registry.find(chat.offering_id).capabilities).to eq(%i[chat vision])
    expect(registry.count).to eq(2)
  end

  it 'finds and filters offerings by the expanded routing contract' do
    expect(registry.find_by_model_alias('gpt-4o')).to eq(chat)
    expect(registry.filter(provider_family: :azure_foundry)).to eq([chat])
    expect(registry.filter(model_family: :openai)).to eq([chat])
    expect(registry.filter(provider_instance: :eastus)).to eq([chat])
    expect(registry.filter(capability: :embedding)).to eq([embedding])
    expect(registry.filter(model_alias: 'titan-embed-text-v2', usage_type: :embedding)).to eq([embedding])
  end
end
