# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Connection do
  describe '#close' do
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
        http_proxy: nil,
        log_regexp_timeout: nil
      )
    end

    it 'nils out the underlying Faraday connection' do
      conn = described_class.new(provider, config)
      expect(conn.connection).not_to be_nil
      conn.close
      expect(conn.connection).to be_nil
    end

    it 'is safe to call multiple times' do
      conn = described_class.new(provider, config)
      conn.close
      expect { conn.close }.not_to raise_error
    end

    it 'calls close on the Faraday connection when supported' do
      conn = described_class.new(provider, config)
      faraday = conn.connection
      allow(faraday).to receive(:close)
      conn.close
      expect(faraday).to have_received(:close)
    end
  end
end
