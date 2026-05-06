# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::ProviderContract do
  let(:provider_class) do
    Class.new(Legion::Extensions::Llm::Provider) do
      def self.slug = :contract_spec
      def self.capabilities = %i[chat stream_chat embed image]
      def self.configuration_requirements = []
      def self.local? = false
      def self.remote? = true
      def self.assume_models_exist? = false

      def ensure_configured! = nil
      def api_base = 'http://example.invalid'
      def models_url = '/v1/models'
      def parse_list_models_response(*) = []
    end
  end

  it 'requires canonical keyword provider methods' do
    expected = {
      chat: [%i[keyreq messages], %i[keyreq model]],
      stream_chat: [%i[keyreq messages], %i[keyreq model]],
      embed: [%i[keyreq text], %i[keyreq model]],
      image: [%i[keyreq prompt], %i[keyreq model]],
      list_models: [%i[key live], %i[keyrest filters]],
      discover_offerings: [%i[key live], %i[keyrest filters]],
      health: [%i[key live]],
      count_tokens: [%i[keyreq messages], %i[keyreq model], %i[key params]]
    }

    expected.each do |method_name, required_parameters|
      parameters = provider_class.instance_method(method_name).parameters
      required_parameters.each do |required_parameter|
        expect(parameters).to include(required_parameter), "#{method_name} missing #{required_parameter.inspect}"
      end
      expect(parameters).not_to include(%i[req messages])
      expect(parameters).not_to include(%i[req text])
      expect(parameters).not_to include(%i[req prompt])
    end
  end

  it 'rejects positional canonical arguments' do
    provider = provider_class.new(
      request_timeout: 30,
      max_retries: 0,
      retry_interval: 0,
      retry_backoff_factor: 0,
      retry_interval_randomness: 0
    )

    expect { provider.chat([], model: 'model') }.to raise_error(ArgumentError)
    expect { provider.stream_chat([], model: 'model') }.to raise_error(ArgumentError)
    expect { provider.embed('text', model: 'model') }.to raise_error(ArgumentError)
    expect { provider.image('prompt', model: 'model') }.to raise_error(ArgumentError)
    expect { provider.count_tokens([], model: 'model') }.to raise_error(ArgumentError)
  end
end
