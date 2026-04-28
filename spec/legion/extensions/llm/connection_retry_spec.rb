# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Connection do
  describe 'retry middleware configuration' do
    let(:provider) do
      instance_double(
        Legion::Extensions::Llm::Provider,
        api_base: 'https://example.com',
        configured?: true,
        headers: {}
      )
    end

    let(:config) do
      instance_double(
        Legion::Extensions::Llm::Configuration,
        request_timeout: 300,
        max_retries: 3,
        retry_interval: 0.1,
        retry_interval_randomness: 0.5,
        retry_backoff_factor: 2,
        http_proxy: nil
      )
    end

    it 'retries POST requests for transient failures' do
      connection = described_class.new(provider, config).connection
      retry_handler = connection.builder.handlers.find { |handler| handler.klass == Faraday::Retry::Middleware }
      retry_options = retry_handler.instance_variable_get(:@args).first

      expect(retry_options[:methods]).to include(:post)
    end
  end
end
