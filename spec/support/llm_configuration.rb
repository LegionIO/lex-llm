# frozen_string_literal: true

Legion::Extensions::Llm.configure do |config|
  config.max_retries = 0
  config.retry_backoff_factor = 0
  config.retry_interval = 0
  config.retry_interval_randomness = 0
end

RSpec.shared_context 'with configured Legion::Extensions::Llm' do
  before do
    Legion::Extensions::Llm.configure do |config|
      # Disable retries in tests for deterministic, fast failures.
      config.max_retries = 0
      config.request_timeout = 600
      config.retry_backoff_factor = 0
      config.retry_interval = 0
      config.retry_interval_randomness = 0
    end
  end
end
