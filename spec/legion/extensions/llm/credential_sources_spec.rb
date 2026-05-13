# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'base64'

RSpec.describe Legion::Extensions::Llm::CredentialSources do
  let(:mod) { described_class }

  describe '.env' do
    it 'returns stripped value for existing env var' do
      allow(ENV).to receive(:fetch).with('TEST_KEY_123', nil).and_return("  my_value  \n")
      expect(mod.env('TEST_KEY_123')).to eq('my_value')
    end

    it 'returns nil for missing env var' do
      allow(ENV).to receive(:fetch).with('MISSING_KEY_XYZ', nil).and_return(nil)
      expect(mod.env('MISSING_KEY_XYZ')).to be_nil
    end

    it 'returns nil for blank env var' do
      allow(ENV).to receive(:fetch).with('BLANK_KEY', nil).and_return('   ')
      expect(mod.env('BLANK_KEY')).to be_nil
    end

    it 'returns nil for empty string env var' do
      allow(ENV).to receive(:fetch).with('EMPTY_KEY', nil).and_return('')
      expect(mod.env('EMPTY_KEY')).to be_nil
    end
  end

  describe '.claude_config' do
    around do |example|
      described_class.instance_variable_set(:@claude_config, nil)
      example.run
      described_class.instance_variable_set(:@claude_config, nil)
    end

    it 'returns a hash from merged Claude settings files' do
      Dir.mktmpdir do |dir|
        user_path = File.join(dir, 'user_settings.json')
        project_path = File.join(dir, 'project_settings.json')

        File.write(user_path, '{"model":"claude-sonnet","env":{"ANTHROPIC_API_KEY":"sk-user"}}')
        File.write(project_path, '{"model":"claude-opus"}')

        stub_const('Legion::Extensions::Llm::CredentialSources::CLAUDE_SETTINGS', user_path)
        stub_const('Legion::Extensions::Llm::CredentialSources::CLAUDE_PROJECT', project_path)

        result = mod.claude_config
        expect(result[:model]).to eq('claude-opus')
        expect(result.dig(:env, :ANTHROPIC_API_KEY)).to eq('sk-user')
      end
    end

    it 'is memoized' do
      stub_const('Legion::Extensions::Llm::CredentialSources::CLAUDE_SETTINGS', '/nonexistent/a.json')
      stub_const('Legion::Extensions::Llm::CredentialSources::CLAUDE_PROJECT', '/nonexistent/b.json')

      first = mod.claude_config
      second = mod.claude_config
      expect(first).to equal(second)
    end

    it 'returns empty hash when both files are missing' do
      stub_const('Legion::Extensions::Llm::CredentialSources::CLAUDE_SETTINGS', '/nonexistent/a.json')
      stub_const('Legion::Extensions::Llm::CredentialSources::CLAUDE_PROJECT', '/nonexistent/b.json')

      expect(mod.claude_config).to eq({})
    end
  end

  describe '.claude_config_value' do
    around do |example|
      described_class.instance_variable_set(:@claude_config, nil)
      example.run
      described_class.instance_variable_set(:@claude_config, nil)
    end

    it 'reads value by symbol key' do
      described_class.instance_variable_set(:@claude_config, { model: 'claude-opus' })
      expect(mod.claude_config_value(:model)).to eq('claude-opus')
    end

    it 'falls back to string key' do
      described_class.instance_variable_set(:@claude_config, { 'model' => 'claude-opus' })
      expect(mod.claude_config_value(:model)).to eq('claude-opus')
    end

    it 'returns nil for missing key' do
      described_class.instance_variable_set(:@claude_config, {})
      expect(mod.claude_config_value(:missing)).to be_nil
    end
  end

  describe '.claude_env_value' do
    around do |example|
      described_class.instance_variable_set(:@claude_config, nil)
      example.run
      described_class.instance_variable_set(:@claude_config, nil)
    end

    it 'reads from env hash with symbol key' do
      described_class.instance_variable_set(:@claude_config, { env: { ANTHROPIC_API_KEY: 'sk-123' } })
      expect(mod.claude_env_value(:ANTHROPIC_API_KEY)).to eq('sk-123')
    end

    it 'falls back to string key in env hash' do
      described_class.instance_variable_set(:@claude_config, { env: { 'ANTHROPIC_API_KEY' => 'sk-456' } })
      expect(mod.claude_env_value(:ANTHROPIC_API_KEY)).to eq('sk-456')
    end

    it 'returns nil when env hash is missing' do
      described_class.instance_variable_set(:@claude_config, {})
      expect(mod.claude_env_value(:ANTHROPIC_API_KEY)).to be_nil
    end

    it 'returns nil when key is not in env hash' do
      described_class.instance_variable_set(:@claude_config, { env: { OTHER: 'val' } })
      expect(mod.claude_env_value(:ANTHROPIC_API_KEY)).to be_nil
    end
  end

  describe '.codex_token' do
    let(:future_exp) { Time.now.to_i + 3600 }
    let(:past_exp) { Time.now.to_i - 3600 }

    def make_jwt(payload)
      header = Base64.urlsafe_encode64('{"alg":"HS256"}', padding: false)
      body = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
      sig = Base64.urlsafe_encode64('fakesig', padding: false)
      "#{header}.#{body}.#{sig}"
    end

    it 'returns bearer token when auth_mode is chatgpt and token is valid' do
      token = make_jwt(exp: future_exp)
      auth_json = JSON.generate(auth_mode: 'chatgpt', bearer_token: token)

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'auth.json')
        File.write(path, auth_json)
        stub_const('Legion::Extensions::Llm::CredentialSources::CODEX_AUTH', path)

        expect(mod.codex_token).to eq(token)
      end
    end

    it 'returns nil when auth_mode is not chatgpt' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'auth.json')
        File.write(path, JSON.generate(auth_mode: 'api_key', bearer_token: 'some-token'))
        stub_const('Legion::Extensions::Llm::CredentialSources::CODEX_AUTH', path)

        expect(mod.codex_token).to be_nil
      end
    end

    it 'returns nil when bearer_token is missing' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'auth.json')
        File.write(path, JSON.generate(auth_mode: 'chatgpt'))
        stub_const('Legion::Extensions::Llm::CredentialSources::CODEX_AUTH', path)

        expect(mod.codex_token).to be_nil
      end
    end

    it 'returns nil when token is expired' do
      token = make_jwt(exp: past_exp)

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'auth.json')
        File.write(path, JSON.generate(auth_mode: 'chatgpt', bearer_token: token))
        stub_const('Legion::Extensions::Llm::CredentialSources::CODEX_AUTH', path)

        expect(mod.codex_token).to be_nil
      end
    end

    it 'returns nil when codex auth file is missing' do
      stub_const('Legion::Extensions::Llm::CredentialSources::CODEX_AUTH', '/nonexistent/auth.json')
      expect(mod.codex_token).to be_nil
    end
  end

  describe '.codex_openai_key' do
    it 'returns the OPENAI_API_KEY from codex auth file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'auth.json')
        File.write(path, JSON.generate(OPENAI_API_KEY: "  sk-proj-abc123  \n"))
        stub_const('Legion::Extensions::Llm::CredentialSources::CODEX_AUTH', path)

        expect(mod.codex_openai_key).to eq('sk-proj-abc123')
      end
    end

    it 'returns nil when key is missing' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'auth.json')
        File.write(path, '{}')
        stub_const('Legion::Extensions::Llm::CredentialSources::CODEX_AUTH', path)

        expect(mod.codex_openai_key).to be_nil
      end
    end

    it 'returns nil when value is blank' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'auth.json')
        File.write(path, JSON.generate(OPENAI_API_KEY: '   '))
        stub_const('Legion::Extensions::Llm::CredentialSources::CODEX_AUTH', path)

        expect(mod.codex_openai_key).to be_nil
      end
    end

    it 'returns nil when file is missing' do
      stub_const('Legion::Extensions::Llm::CredentialSources::CODEX_AUTH', '/nonexistent/auth.json')
      expect(mod.codex_openai_key).to be_nil
    end
  end

  describe '.setting' do
    it 'digs into Legion::Settings when defined' do
      Legion::Settings.merge_settings(:llm, { provider: 'anthropic' })
      expect(mod.setting(:llm, :provider)).to eq('anthropic')
    end

    it 'returns nil for missing paths' do
      expect(mod.setting(:nonexistent, :deep, :path)).to be_nil
    end

    it 'returns nil when dig raises an error' do
      allow(Legion::Settings).to receive(:dig).and_raise(NoMethodError, 'undefined method')
      expect(mod.setting(:llm, :provider)).to be_nil
    end
  end

  describe '.socket_open?' do
    it 'returns true when port is open' do
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      expect(mod.socket_open?('127.0.0.1', port)).to be true
    ensure
      server&.close
    end

    it 'returns false when port is closed' do
      expect(mod.socket_open?('127.0.0.1', 39_999, timeout: 0.05)).to be false
    end

    it 'returns false when connection is refused' do
      fake_sock = instance_double(Socket)
      allow(Socket).to receive(:new).and_return(fake_sock)
      allow(fake_sock).to receive(:setsockopt)
      allow(fake_sock).to receive(:connect_nonblock).and_raise(Errno::ECONNREFUSED)
      allow(fake_sock).to receive(:close)

      expect(mod.socket_open?('192.0.2.1', 80, timeout: 0.05)).to be false
    end

    it 'uses 0.1 second default timeout' do
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      expect(mod.socket_open?('127.0.0.1', port, timeout: 0.1)).to be true
    ensure
      server&.close
    end
  end

  describe '.http_ok?' do
    it 'returns true for a successful HTTP response' do
      fake_response = instance_double(Faraday::Response, status: 200)
      fake_conn = instance_double(Faraday::Connection, get: fake_response, close: nil)
      allow(Faraday).to receive(:new).and_return(fake_conn)

      expect(mod.http_ok?('http://localhost:8080', path: '/health')).to be true
    end

    it 'returns false for a non-200 HTTP response' do
      fake_response = instance_double(Faraday::Response, status: 503)
      fake_conn = instance_double(Faraday::Connection, get: fake_response, close: nil)
      allow(Faraday).to receive(:new).and_return(fake_conn)

      expect(mod.http_ok?('http://localhost:8080', path: '/health')).to be false
    end

    it 'returns false on connection error' do
      allow(Faraday).to receive(:new).and_raise(Faraday::ConnectionFailed.new('refused'))

      expect(mod.http_ok?('http://localhost:9999', path: '/')).to be false
    end

    it 'returns false on timeout' do
      allow(Faraday).to receive(:new).and_raise(Faraday::TimeoutError)

      expect(mod.http_ok?('http://localhost:9999', path: '/')).to be false
    end
  end

  describe '.dedup_credentials' do
    it 'deduplicates by api_key' do
      candidates = {
        source_a: { api_key: 'sk-same', base_url: 'http://a' },
        source_b: { api_key: 'sk-same', base_url: 'http://b' },
        source_c: { api_key: 'sk-diff', base_url: 'http://c' }
      }
      result = mod.dedup_credentials(candidates)
      expect(result.keys).to contain_exactly(:source_a, :source_c)
    end

    it 'deduplicates by bearer_token' do
      candidates = {
        source_a: { bearer_token: 'tok-1' },
        source_b: { bearer_token: 'tok-1' }
      }
      result = mod.dedup_credentials(candidates)
      expect(result.keys).to contain_exactly(:source_a)
    end

    it 'keeps entries without credential values' do
      candidates = {
        source_a: { base_url: 'http://a' },
        source_b: { base_url: 'http://b' }
      }
      result = mod.dedup_credentials(candidates)
      expect(result.keys).to contain_exactly(:source_a, :source_b)
    end

    it 'first source wins on duplicates' do
      candidates = {
        first: { api_key: 'sk-same', note: 'winner' },
        second: { api_key: 'sk-same', note: 'loser' }
      }
      result = mod.dedup_credentials(candidates)
      expect(result[:first][:note]).to eq('winner')
      expect(result).not_to have_key(:second)
    end
  end

  describe '.credential_hash' do
    it 'returns SHA-256 hex of api_key' do
      config = { api_key: 'sk-test123' }
      expected = Digest::SHA256.hexdigest('sk-test123')
      expect(mod.credential_hash(config)).to eq(expected)
    end

    it 'returns SHA-256 hex of bearer_token when no api_key' do
      config = { bearer_token: 'tok-abc' }
      expected = Digest::SHA256.hexdigest('tok-abc')
      expect(mod.credential_hash(config)).to eq(expected)
    end

    it 'returns SHA-256 hex of access_token as last resort' do
      config = { access_token: 'at-xyz' }
      expected = Digest::SHA256.hexdigest('at-xyz')
      expect(mod.credential_hash(config)).to eq(expected)
    end

    it 'prefers api_key over bearer_token' do
      config = { api_key: 'sk-key', bearer_token: 'tok-bear' }
      expected = Digest::SHA256.hexdigest('sk-key')
      expect(mod.credential_hash(config)).to eq(expected)
    end

    it 'returns nil when no credential fields present' do
      config = { base_url: 'http://example.com' }
      expect(mod.credential_hash(config)).to be_nil
    end

    it 'returns nil for empty config' do
      expect(mod.credential_hash({})).to be_nil
    end
  end

  describe '.localhost?' do
    it 'returns true for localhost' do
      expect(mod.localhost?('http://localhost:8080')).to be true
    end

    it 'returns true for 127.0.0.1' do
      expect(mod.localhost?('http://127.0.0.1:3000/api')).to be true
    end

    it 'returns true for ::1' do
      expect(mod.localhost?('http://[::1]:8080')).to be true
    end

    it 'returns false for remote host' do
      expect(mod.localhost?('https://api.example.com')).to be false
    end

    it 'returns false for nil' do
      expect(mod.localhost?(nil)).to be false
    end

    it 'returns false for malformed URL' do
      expect(mod.localhost?('not a url at all')).to be false
    end
  end

  describe '.read_json (private)' do
    it 'parses a valid JSON file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'test.json')
        File.write(path, '{"key": "value"}')
        result = mod.send(:read_json, path)
        expect(result[:key]).to eq('value')
      end
    end

    it 'returns empty hash for missing file' do
      result = mod.send(:read_json, '/nonexistent/file.json')
      expect(result).to eq({})
    end

    it 'returns empty hash for invalid JSON' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'bad.json')
        File.write(path, 'not json{{{')
        result = mod.send(:read_json, path)
        expect(result).to eq({})
      end
    end

    it 'returns empty hash for empty file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'empty.json')
        File.write(path, '')
        result = mod.send(:read_json, path)
        expect(result).to eq({})
      end
    end
  end

  describe '.token_valid? (private)' do
    def make_jwt(payload)
      header = Base64.urlsafe_encode64('{"alg":"HS256"}', padding: false)
      body = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
      sig = Base64.urlsafe_encode64('fakesig', padding: false)
      "#{header}.#{body}.#{sig}"
    end

    it 'returns true for non-expired token' do
      token = make_jwt(exp: Time.now.to_i + 3600)
      expect(mod.send(:token_valid?, token)).to be true
    end

    it 'returns false for expired token' do
      token = make_jwt(exp: Time.now.to_i - 3600)
      expect(mod.send(:token_valid?, token)).to be false
    end

    it 'returns true when token has no exp claim' do
      token = make_jwt(sub: 'user')
      expect(mod.send(:token_valid?, token)).to be true
    end

    it 'returns true on parse error (malformed token)' do
      expect(mod.send(:token_valid?, 'not.a.jwt')).to be true
    end

    it 'returns true for nil token' do
      expect(mod.send(:token_valid?, nil)).to be true
    end
  end
end
