# frozen_string_literal: true

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  status_suffix = ENV['TEST_ENV_NUMBER'].to_s
  config.example_status_persistence_file_path = ".rspec_status#{status_suffix}"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before do
    LexLLM::Provider.providers.clear
  end
end
