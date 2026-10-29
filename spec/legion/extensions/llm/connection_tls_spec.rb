# frozen_string_literal: true

require 'spec_helper'
require 'faraday/net_http'
require_relative '../../../support/tls_endpoint'

RSpec.describe Legion::Extensions::Llm::Connection do
  around do |example|
    saved = Legion::Settings.loader.settings[:extensions]
    Legion::Settings.loader.settings[:extensions] = { llm: Legion::Extensions::Llm.default_settings }
    example.run
  ensure
    if saved.nil?
      Legion::Settings.loader.settings.delete(:extensions)
    else
      Legion::Settings.loader.settings[:extensions] = saved
    end
  end

  { typhoeus: Faraday::ConnectionFailed, net_http: Faraday::SSLError }.each do |adapter, error_class|
    context "with the #{adapter} adapter" do
      let(:endpoint) { SpecSupport::TlsEndpoint.new }
      let(:config) do
        Legion::Extensions::Llm::Configuration.new.tap do |configuration|
          configuration.logger = Logger.new(File::NULL)
          configuration.max_retries = 0
          configuration.request_timeout = 3
        end
      end
      let(:provider) do
        instance_double(Legion::Extensions::Llm::Provider,
                        api_base: endpoint.url,
                        headers: { 'Authorization' => 'Bearer tls-fixture' },
                        parse_error: nil)
      end
      let(:connection) do
        described_class.new(provider, config).tap do |client|
          client.connection.builder.adapter(adapter)
          client.connection.proxy = nil
        end
      end

      after do
        connection.close
        endpoint.close
      end

      context 'with the default disabled verification' do
        let(:endpoint) { SpecSupport::TlsEndpoint.new(subject_alt_name: 'DNS:wrong.example.test') }

        it 'allows an authenticated request despite an untrusted and mismatched certificate' do
          response = connection.get('/tls-check')
          endpoint.finish

          expect(response.status).to eq(200)
          expect(response.body).to eq('status' => 'ok')
          expect(endpoint.requests.one? { |request| request.match?(/^authorization: Bearer tls-fixture\r?$/i) }).to be(true)
        end
      end

      context 'when TLS verification is enabled in Legion settings' do
        before do
          Legion::Settings.loader.settings[:extensions][:llm][:ssl][:verify] = true
        end

        it 'rejects an untrusted certificate before sending an authenticated HTTP request' do
          expect { connection.get('/tls-check') }.to raise_error(error_class)
          endpoint.finish

          expect(endpoint.requests).to be_empty
        end

        it 'accepts a matching certificate through an explicitly trusted custom CA' do
          connection.connection.ssl.ca_file = endpoint.ca_file.path

          response = connection.get('/tls-check')
          endpoint.finish

          expect(response.status).to eq(200)
          expect(response.body).to eq('status' => 'ok')
          expect(endpoint.requests.one? { |request| request.match?(/^authorization: Bearer tls-fixture\r?$/i) }).to be(true)
        end
      end

      context 'when TLS verification is enabled for a trusted wrong-host certificate' do
        let(:endpoint) { SpecSupport::TlsEndpoint.new(subject_alt_name: 'DNS:wrong.example.test') }

        before do
          Legion::Settings.loader.settings[:extensions][:llm][:ssl][:verify] = true
        end

        it 'rejects the peer before sending an authenticated HTTP request' do
          connection.connection.ssl.ca_file = endpoint.ca_file.path

          expect { connection.get('/tls-check') }.to raise_error(error_class)
          endpoint.finish

          expect(endpoint.requests).to be_empty
        end
      end
    end
  end
end
