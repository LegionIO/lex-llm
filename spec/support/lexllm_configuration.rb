# frozen_string_literal: true

LexLLM.configure do |config|
  config.model_registry_class = 'Model'
  config.max_retries = 0
  config.retry_backoff_factor = 0
  config.retry_interval = 0
  config.retry_interval_randomness = 0
end

RSpec.shared_context 'with configured LexLLM' do
  before do
    LexLLM.configure do |config|
      # Disable retries in tests for deterministic, fast failures.
      config.max_retries = 0
      config.model_registry_class = 'Model'
      config.request_timeout = 600
      config.retry_backoff_factor = 0
      config.retry_interval = 0
      config.retry_interval_randomness = 0
    end
  end
end
