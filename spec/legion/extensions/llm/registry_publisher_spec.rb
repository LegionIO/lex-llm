# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::RegistryPublisher do
  subject(:publisher) { described_class.new(provider_family: :ollama, builder: builder) }

  let(:builder) { instance_double(Legion::Extensions::Llm::RegistryEventBuilder) }

  describe '#app_id' do
    it 'includes the provider family' do
      expect(publisher.app_id).to eq('lex-llm-ollama')
    end
  end

  describe '#provider_family' do
    it 'normalizes to a downcased symbol' do
      pub = described_class.new(provider_family: 'Anthropic', builder: builder)
      expect(pub.provider_family).to eq(:anthropic)
    end
  end
end
