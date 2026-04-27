# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LexLLM::ActiveRecord::ActsAs do
  include_context 'with fake llm provider'

  let(:model) { 'fake-chat-model' }

  describe 'when global configuration is missing' do
    around do |example|
      # Save current config
      original_config = LexLLM.instance_variable_get(:@config)

      # Reset configuration to simulate missing global config
      LexLLM.instance_variable_set(:@config, LexLLM::Configuration.new)

      example.run

      # Restore original config
      LexLLM.instance_variable_set(:@config, original_config)
    end

    it 'works when using chat with a custom context' do
      context = LexLLM.context do |config|
        config.fake_llm_api_key = 'test-key'
      end

      chat = Chat.create!(model: model, provider: 'fake_llm', assume_model_exists: true, context: context)

      expect(chat.instance_variable_get(:@context)).to eq(context)
    end
  end

  describe 'with global configuration present' do
    include_context 'with configured LexLLM'

    it 'works with custom context even when global config exists' do
      # Create a different API key in custom context
      custom_context = LexLLM.context do |config|
        config.fake_llm_api_key = 'different-key'
      end

      chat = Chat.create!(model: model, provider: 'fake_llm', assume_model_exists: true, context: custom_context)

      expect(chat.instance_variable_get(:@context)).to eq(custom_context)
      expect(chat.instance_variable_get(:@context).config.fake_llm_api_key).to eq('different-key')
    end
  end
end
