# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LexLLM::Error do
  it 'handles invalid API keys gracefully' do
    LexLLM.configure do |config|
      config.openai_api_key = 'invalid-key'
    end

    chat = LexLLM.chat(model: 'gpt-4.1-nano')

    expect do
      chat.ask('Hello')
    end.to raise_error(LexLLM::UnauthorizedError)
  end
end
