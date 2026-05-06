# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Error do
  describe '#initialize' do
    context 'with a string argument' do
      it 'treats the string as the message' do
        error = described_class.new('something went wrong')
        expect(error.message).to eq('something went wrong')
      end

      it 'sets response to nil' do
        error = described_class.new('something went wrong')
        expect(error.response).to be_nil
      end

      it 'does not raise NoMethodError' do
        expect { described_class.new('something went wrong') }.not_to raise_error
      end
    end

    context 'with a response object and message' do
      let(:response) { Struct.new(:status, :body).new(500, '{"error":"server error"}') }

      it 'stores the response' do
        error = described_class.new(response, 'server error')
        expect(error.response).to eq(response)
      end

      it 'uses the provided message' do
        error = described_class.new(response, 'server error')
        expect(error.message).to eq('server error')
      end
    end

    context 'with a response object only' do
      let(:response) { Struct.new(:status, :body).new(500, 'raw body') }

      it 'falls back to response body for the message' do
        error = described_class.new(response)
        expect(error.message).to eq('raw body')
      end
    end

    context 'with no arguments' do
      it 'works without raising' do
        error = described_class.new
        expect(error.response).to be_nil
        expect(error.message).to eq('Legion::Extensions::Llm::Error')
      end
    end
  end

  describe 'subclasses' do
    it 'inherits the string argument fix' do
      error = Legion::Extensions::Llm::BadRequestError.new('bad request')
      expect(error.message).to eq('bad request')
      expect(error.response).to be_nil
    end
  end

  describe Legion::Extensions::Llm::Errors::UnsupportedCapability do
    it 'formats provider capability failures' do
      error = described_class.new(provider: :ollama, capability: :image, model: 'llama3')

      expect(error.message).to eq('Provider ollama does not support image for llama3')
      expect(error.provider).to eq(:ollama)
      expect(error.capability).to eq(:image)
      expect(error.model).to eq('llama3')
    end
  end

  describe Legion::Extensions::Llm::UnsupportedCapabilityError do
    it 'keeps string message compatibility for existing callers' do
      error = described_class.new('not supported')

      expect(error.message).to eq('not supported')
    end

    it 'accepts the shared keyword initializer' do
      error = described_class.new(provider: :openai, capability: :embed)

      expect(error.message).to eq('Provider openai does not support embed')
    end
  end
end
