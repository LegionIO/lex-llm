# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Configuration do
  describe 'DSL defaults' do
    subject(:config) { described_class.new }

    it 'applies core default values' do
      expect(config.request_timeout).to eq(300)
      expect(config.max_retries).to eq(3)
      expect(config.retry_interval).to eq(0.1)
      expect(config.retry_backoff_factor).to eq(2)
      expect(config.retry_interval_randomness).to eq(0.5)
    end

    it 'exposes a discoverable options API' do
      expect(described_class.options).to include(
        :request_timeout,
        :default_model,
        :default_embedding_model,
        :model_registry_file
      )
    end

    it 'includes prompt caching configuration options' do
      expect(described_class.options).to include(:llm_cache_enabled, :cache_control_prefix_tokens)
    end

    it 'defaults llm_cache_enabled to true' do
      expect(config.llm_cache_enabled).to be true
    end

    it 'defaults cache_control_prefix_tokens to 4' do
      expect(config.cache_control_prefix_tokens).to eq(4)
    end
  end

  describe '.register_provider_options' do
    after do
      # Clean up test options to avoid polluting other specs
      %i[test_api_key test_api_base].each do |key|
        described_class.send(:option_keys).delete(key)
        described_class.send(:defaults).delete(key)
        described_class.send(:remove_method, key) if described_class.method_defined?(key)
        described_class.send(:remove_method, :"#{key}=") if described_class.method_defined?(:"#{key}=")
      end
    end

    it 'registers new options that become accessible on instances' do
      described_class.register_provider_options(%i[test_api_key test_api_base])

      config = described_class.new
      expect(config).to respond_to(:test_api_key)
      expect(config).to respond_to(:test_api_base)
    end

    it 'adds registered options to the options list' do
      described_class.register_provider_options(%i[test_api_key test_api_base])

      expect(described_class.options).to include(:test_api_key, :test_api_base)
    end

    it 'is idempotent — duplicate registrations do not add duplicates' do
      described_class.register_provider_options(%i[test_api_key])
      described_class.register_provider_options(%i[test_api_key])

      count = described_class.options.count(:test_api_key)
      expect(count).to eq(1)
    end

    it 'accepts string keys and normalizes them to symbols' do
      described_class.register_provider_options(%w[test_api_key])

      expect(described_class.options).to include(:test_api_key)
    end
  end
end
