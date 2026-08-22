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

  describe '0.8.0 rip — legacy defaults deleted' do
    it 'provides no discover_instances or provider_aliases defaults' do
      expect(provider_module).not_to respond_to(:discover_instances)
      expect(provider_module).not_to respond_to(:provider_aliases)
    end
  end

  it 'does not expose legion-llm registry mutation hooks' do
    expect(provider_module).not_to respond_to(:register_discovered_instances)
    expect(provider_module).not_to respond_to(:rediscover!)
  end
end
