# frozen_string_literal: true

require 'fileutils'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  status_suffix = ENV['TEST_ENV_NUMBER'].to_s
  config.example_status_persistence_file_path = ".rspec_status#{status_suffix}"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.around do |example|
    cassette_name = example.full_description.parameterize(separator: '_')
                           .delete_prefix('lexllm_')
                           .delete_prefix('rubyllm_')
    legacy_cassette_name = cassette_name.gsub('lexllm_schema', 'rubyllm_schema')
    cassette_path = File.join(VCR.configuration.cassette_library_dir, "#{cassette_name}.yml")
    legacy_cassette_path = File.join(VCR.configuration.cassette_library_dir, "#{legacy_cassette_name}.yml")
    cassette_existed = File.exist?(cassette_path)

    if !cassette_existed && legacy_cassette_name != cassette_name && File.exist?(legacy_cassette_path)
      cassette_name = legacy_cassette_name
      cassette_path = legacy_cassette_path
      cassette_existed = true
    end

    VCR.use_cassette(cassette_name) do
      example.run
    end

    FileUtils.rm_f(cassette_path) if example.exception && !cassette_existed
  end
end
