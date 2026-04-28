# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Provider do
  describe '.register' do
    it 'registers provider configuration options on Configuration' do
      provider_key = :test_provider_spec
      option_keys = %i[test_provider_api_key test_provider_api_base]

      provider_class = Class.new(described_class) do
        class << self
          def configuration_options
            %i[test_provider_api_key test_provider_api_base]
          end

          def configuration_requirements
            %i[test_provider_api_key]
          end
        end
      end

      original_providers = described_class.providers.dup

      begin
        described_class.register(provider_key, provider_class)

        config = Legion::Extensions::Llm::Configuration.new
        option_keys.each do |key|
          expect(config).to respond_to(key)
          expect(config).to respond_to("#{key}=")
        end
      ensure
        described_class.providers.replace(original_providers)
        option_keys.each do |key|
          Legion::Extensions::Llm::Configuration.send(:option_keys).delete(key)
          Legion::Extensions::Llm::Configuration.send(:defaults).delete(key)
          Legion::Extensions::Llm::Configuration.class_eval do
            remove_method key if method_defined?(key)
            remove_method :"#{key}=" if method_defined?(:"#{key}=")
          end
        end
      end
    end
  end

  describe 'provider configuration schema' do
    it 'starts with no concrete providers registered by the base gem' do
      expect(described_class.providers).to eq({})
      expect(Legion::Extensions::Llm::Configuration.options).to include(:request_timeout, :model_registry_file)
    end
  end

  describe '#readiness' do
    it 'returns non-live routing readiness metadata without calling provider endpoints' do
      provider_class = Class.new(described_class) do
        def api_base = 'https://provider.invalid'
        def completion_url = '/v1/chat/completions'
        def models_url = '/v1/models'
        def health_url = '/health'
      end
      provider = provider_class.new(Legion::Extensions::Llm.config)

      expect(provider.readiness).to include(
        provider: provider.slug.to_sym,
        configured: true,
        ready: true,
        api_base: 'https://provider.invalid',
        endpoints: { completion: '/v1/chat/completions', models: '/v1/models', health: '/health' },
        health: { checked: false }
      )
    end
  end
end
