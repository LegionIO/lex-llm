# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Context do
  include_context 'with configured Legion::Extensions::Llm'
  include_context 'with fake llm provider'

  describe '#initialize' do
    it 'creates a copy of the global configuration' do
      # Get current config values
      original_model = Legion::Extensions::Llm.config.default_model
      original_log_regexp_timeout = Legion::Extensions::Llm.config.log_regexp_timeout

      # Create context with modified config
      context = Legion::Extensions::Llm.context do |config|
        config.default_model = 'modified-model'
        config.fake_llm_api_key = 'modified-key'
        config.log_regexp_timeout = 5.0
      end

      # Verify global config is unchanged
      expect(Legion::Extensions::Llm.config.default_model).to eq(original_model)
      expect(Legion::Extensions::Llm.config.log_regexp_timeout).to eq(original_log_regexp_timeout)

      # Verify context has modified config
      expect(context.config.default_model).to eq('modified-model')
      expect(context.config.fake_llm_api_key).to eq('modified-key')
      expect(context.config.log_regexp_timeout).to eq(5.0)
    end

    it 'preserves log_regexp_timeout when Regexp timeout is unavailable' do
      allow(Regexp).to receive(:respond_to?).and_call_original
      allow(Regexp).to receive(:respond_to?).with(:timeout).and_return(false)
      allow(Legion::Extensions::Llm.logger).to receive(:warn)

      context = Legion::Extensions::Llm.context do |config|
        config.log_regexp_timeout = 5.0
      end

      expect(context.config.log_regexp_timeout).to eq(5.0)
    end
  end

  describe 'context chat operations' do
    it 'creates a chat with context-specific configuration' do
      context = Legion::Extensions::Llm.context do |config|
        config.default_model = 'fake-chat-model'
      end

      chat = context.chat(provider: :fake_llm, assume_model_exists: true)
      expect(chat.model.id).to eq('fake-chat-model')
    end

    it 'allows specifying a model when creating the chat' do
      context = Legion::Extensions::Llm.context do |config|
        config.default_model = 'fake-chat-model'
      end

      chat = context.chat(model: 'other-fake-chat-model', provider: :fake_llm, assume_model_exists: true)
      expect(chat.model.id).to eq('other-fake-chat-model')
    end
  end

  describe 'context embed operations' do
    it 'respects context-specific embedding model' do
      context = Legion::Extensions::Llm.context do |config|
        config.default_embedding_model = 'fake-embed'
      end

      embedding = context.embed('Test embedding', provider: :fake_llm, assume_model_exists: true)
      expect(embedding.model).to eq('fake-embed')
    end

    it 'allows specifying a model at embed time' do
      context = Legion::Extensions::Llm.context do |config|
        config.default_embedding_model = 'fake-embed'
      end

      embedding = context.embed('Test embedding', model: 'override-embed', provider: :fake_llm,
                                                  assume_model_exists: true)
      expect(embedding.model).to eq('override-embed')
    end
  end

  describe 'multiple independent contexts' do
    it 'allows multiple contexts with different configurations' do
      context1 = Legion::Extensions::Llm.context do |config|
        config.default_model = 'fake-chat-1'
        config.log_regexp_timeout = 5.0
      end

      context2 = Legion::Extensions::Llm.context do |config|
        config.default_model = 'fake-chat-2'
      end

      chat1 = context1.chat(provider: :fake_llm, assume_model_exists: true)
      chat2 = context2.chat(provider: :fake_llm, assume_model_exists: true)

      expect(chat1.model.id).to eq('fake-chat-1')
      expect(context1.config.log_regexp_timeout).to eq(5.0)

      expect(chat2.model.id).to eq('fake-chat-2')
      expected_timeout = Regexp.respond_to?(:timeout) ? (Regexp.timeout || 1.0) : nil
      expect(context2.config.log_regexp_timeout).to eq(expected_timeout)
    end

    it 'ensures changes in one context do not affect another' do
      context1 = Legion::Extensions::Llm.context do |config|
        config.fake_llm_api_key = 'key1'
        config.default_model = 'model1'
      end

      context2 = Legion::Extensions::Llm.context do |config|
        config.fake_llm_api_key = 'key2'
        config.default_model = 'model2'
      end

      # Modify context1 after creation
      context1.config.fake_llm_api_key = 'modified-key1'

      # Context2 should be unaffected
      expect(context2.config.fake_llm_api_key).to eq('key2')
      expect(context2.config.default_model).to eq('model2')
    end
  end
end
