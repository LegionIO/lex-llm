# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::AutoRegistration do
  # Build a fake provider module that extends AutoRegistration,
  # mimicking what a real lex-llm-* provider would look like.
  let(:fake_provider_class) { Class.new }

  let(:provider_module) do
    klass = fake_provider_class
    mod = Module.new do
      extend Legion::Extensions::Llm::AutoRegistration

      const_set(:PROVIDER_FAMILY, :fake_provider)

      define_singleton_method(:provider_class) { klass }
    end
    mod
  end

  describe '#discover_instances' do
    it 'returns an empty hash by default' do
      expect(provider_module.discover_instances).to eq({})
    end
  end

  describe '#provider_aliases' do
    it 'returns an empty alias list by default' do
      expect(provider_module.provider_aliases).to eq([])
    end
  end

  it 'does not expose legion-llm registry mutation hooks' do
    expect(provider_module).not_to respond_to(:register_discovered_instances)
    expect(provider_module).not_to respond_to(:rediscover!)
  end
end
