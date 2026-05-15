# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::ErrorMiddleware do
  describe '.parse_error' do
    let(:provider) { instance_double(Legion::Extensions::Llm::Provider, parse_error: 'provider error') }

    let(:stream_response) do
      Struct.new(:status, :body) do
        def [](key)
          custom[key]
        end

        def []=(key, value)
          custom[key] = value
        end

        private

        def custom
          @custom ||= {}
        end
      end
    end

    it 'maps 502 to ServiceUnavailableError' do
      response = Struct.new(:status, :body).new(502, '{"error":{"message":"down"}}')

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Legion::Extensions::Llm::ServiceUnavailableError)
    end

    it 'maps 503 to ServiceUnavailableError' do
      response = Struct.new(:status, :body).new(503, '{"error":{"message":"down"}}')

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Legion::Extensions::Llm::ServiceUnavailableError)
    end

    it 'maps 504 to ServiceUnavailableError' do
      response = Struct.new(:status, :body).new(504, '{"error":{"message":"timeout"}}')

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Legion::Extensions::Llm::ServiceUnavailableError)
    end

    it 'maps context-length-like 429 errors to ContextLengthExceededError' do
      response = Struct.new(:status, :body).new(429, '{"error":{"message":"Request too large for model"}}')
      provider = instance_double(Legion::Extensions::Llm::Provider, parse_error: 'Request too large for model')

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Legion::Extensions::Llm::ContextLengthExceededError)
    end

    it 'keeps regular 429 errors as RateLimitError' do
      response = Struct.new(:status, :body).new(429, '{"error":{"message":"Rate limit exceeded"}}')
      provider = instance_double(Legion::Extensions::Llm::Provider, parse_error: 'Rate limit exceeded')

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Legion::Extensions::Llm::RateLimitError)
    end

    it 'maps context-length-like 400 errors to ContextLengthExceededError' do
      msg = "This model's maximum context length is 8192 tokens."
      response = Struct.new(:status, :body).new(400, %({"error":{"message":"#{msg}"}}))
      provider = instance_double(Legion::Extensions::Llm::Provider, parse_error: msg)

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Legion::Extensions::Llm::ContextLengthExceededError)
    end

    it 'keeps regular 400 errors as BadRequestError' do
      response = Struct.new(:status, :body).new(400, '{"error":{"message":"Invalid model specified"}}')
      provider = instance_double(Legion::Extensions::Llm::Provider, parse_error: 'Invalid model specified')

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Legion::Extensions::Llm::BadRequestError)
    end

    it 'uses preserved streaming error body when Faraday finalizes an empty response body' do
      response = stream_response.new(500, '')
      response[described_class::STREAM_ERROR_BODY_KEY] =
        '{"error":{"message":"The model rejected chat_template_kwargs"}}'
      provider = instance_double(Legion::Extensions::Llm::Provider)
      allow(provider).to receive(:parse_error) do |error_response|
        error_response.body[/"message"\s*:\s*"([^"]+)"/, 1]
      end

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Legion::Extensions::Llm::ServerError, /chat_template_kwargs/)
    end
  end
end
