# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Provider do
  describe '#readiness' do
    it 'returns non-live routing readiness metadata without calling provider endpoints' do
      provider_class = Class.new(described_class) do
        def api_base = 'https://provider.invalid'
        def completion_url = '/v1/chat/completions'
        def models_url = '/v1/models'
        def health_url = '/health'
      end
      provider = provider_class.new(Legion::Extensions::Llm.config)

      expect(provider.readiness).to include(
        provider: provider.slug.to_sym,
        configured: true,
        ready: true,
        api_base: 'https://provider.invalid',
        endpoints: { completion: '/v1/chat/completions', models: '/v1/models', health: '/health' },
        health: { checked: false }
      )
    end
  end

  describe '#model_allowed?' do
    let(:provider_class) do
      Class.new(described_class) do
        attr_writer :settings

        def api_base = 'https://test.invalid'

        def settings
          @settings || {}
        end
      end
    end

    let(:provider) { provider_class.new(Legion::Extensions::Llm.config) }

    context 'with no whitelist or blacklist' do
      it 'allows all models' do
        expect(provider.model_allowed?('gpt-5')).to be true
        expect(provider.model_allowed?('claude-opus')).to be true
      end
    end

    context 'with whitelist' do
      before { provider.settings = { model_whitelist: %w[gpt claude] } }

      it 'allows models matching whitelist patterns' do
        expect(provider.model_allowed?('gpt-5')).to be true
        expect(provider.model_allowed?('claude-opus-4')).to be true
      end

      it 'blocks models not matching whitelist patterns' do
        expect(provider.model_allowed?('llama-3')).to be false
      end
    end

    context 'with blacklist' do
      before { provider.settings = { model_blacklist: %w[deprecated preview] } }

      it 'blocks models matching blacklist patterns' do
        expect(provider.model_allowed?('gpt-5-preview')).to be false
        expect(provider.model_allowed?('deprecated-model')).to be false
      end

      it 'allows models not matching blacklist patterns' do
        expect(provider.model_allowed?('gpt-5')).to be true
      end
    end

    context 'with both whitelist and blacklist' do
      before do
        provider.settings = {
          model_whitelist: %w[gpt],
          model_blacklist: %w[preview]
        }
      end

      it 'applies whitelist first, then blacklist' do
        expect(provider.model_allowed?('gpt-5')).to be true
        expect(provider.model_allowed?('gpt-5-preview')).to be false
        expect(provider.model_allowed?('llama-3')).to be false
      end
    end

    context 'with case-insensitive matching' do
      before { provider.settings = { model_whitelist: %w[GPT] } }

      it 'matches case-insensitively' do
        expect(provider.model_allowed?('GPT-5')).to be true
        expect(provider.model_allowed?('gpt-5')).to be true
      end
    end
  end

  describe 'multi-host URL resolution' do
    let(:provider_class) do
      Class.new(described_class) do
        attr_writer :settings

        def api_base = resolve_base_url || 'https://fallback.invalid'

        def settings
          @settings || {}
        end
      end
    end

    let(:provider) { provider_class.new(Legion::Extensions::Llm.config) }

    describe '#config_base_url' do
      it 'returns the base_url from settings' do
        provider.settings = { base_url: 'http://localhost:11434' }
        expect(provider.config_base_url).to eq('http://localhost:11434')
      end

      it 'returns nil when no settings' do
        expect(provider.config_base_url).to be_nil
      end
    end

    describe '#strip_scheme' do
      it 'strips http scheme' do
        expect(provider.strip_scheme('http://localhost:11434')).to eq('localhost:11434')
      end

      it 'strips https scheme' do
        expect(provider.strip_scheme('https://api.example.com')).to eq('api.example.com')
      end

      it 'returns as-is when no scheme' do
        expect(provider.strip_scheme('localhost:11434')).to eq('localhost:11434')
      end
    end

    describe '#tls_enabled?' do
      it 'returns false by default' do
        expect(provider.tls_enabled?).to be false
      end

      it 'returns true when tls.enabled is true' do
        provider.settings = { tls: { enabled: true } }
        expect(provider.tls_enabled?).to be true
      end

      it 'returns false when tls.enabled is false' do
        provider.settings = { tls: { enabled: false } }
        expect(provider.tls_enabled?).to be false
      end
    end

    describe '#resolve_base_url' do
      it 'returns nil when no config_base_url' do
        expect(provider.resolve_base_url).to be_nil
      end

      it 'returns the single URL when unreachable (falls back to first)' do
        provider.settings = { base_url: 'unreachable.invalid:9999' }
        allow(provider).to receive(:url_reachable?).and_return(false)

        expect(provider.resolve_base_url).to eq('http://unreachable.invalid:9999')
      end

      it 'handles array of URLs and picks first reachable' do
        provider.settings = { base_url: ['unreachable.invalid:9999', 'reachable.invalid:8080'] }
        allow(provider).to receive(:url_reachable?).and_return(false, true)

        result = provider.resolve_base_url
        expect(result).to eq('http://reachable.invalid:8080')
      end

      it 'falls back to first URL if none are reachable' do
        provider.settings = { base_url: ['a.invalid:1', 'b.invalid:2'] }
        allow(provider).to receive(:url_reachable?).and_return(false, false)

        expect(provider.resolve_base_url).to eq('http://a.invalid:1')
      end
    end

    describe '#url_reachable?' do
      it 'returns false for unreachable URLs' do
        expect(provider.url_reachable?('http://unreachable.invalid:9999')).to be false
      end
    end
  end

  describe 'cache tier selection' do
    let(:provider_class) do
      Class.new(described_class) do
        attr_writer :settings

        def api_base = 'https://test.invalid'

        def settings
          @settings || {}
        end
      end
    end

    let(:provider) { provider_class.new(Legion::Extensions::Llm.config) }

    describe '#cache_local_instance?' do
      it 'returns true for localhost URLs' do
        provider.settings = { base_url: 'http://localhost:11434' }
        expect(provider.cache_local_instance?).to be true
      end

      it 'returns true for 127.0.0.1 URLs' do
        provider.settings = { base_url: 'http://127.0.0.1:11434' }
        expect(provider.cache_local_instance?).to be true
      end

      it 'returns true for ::1 URLs' do
        provider.settings = { base_url: 'http://[::1]:11434' }
        expect(provider.cache_local_instance?).to be true
      end

      it 'returns false for remote URLs' do
        provider.settings = { base_url: 'https://api.openai.com' }
        expect(provider.cache_local_instance?).to be false
      end

      it 'returns true if any URL in array is local' do
        provider.settings = { base_url: ['https://api.openai.com', 'http://localhost:11434'] }
        expect(provider.cache_local_instance?).to be true
      end

      it 'returns false when no base_url configured' do
        expect(provider.cache_local_instance?).to be false
      end
    end

    describe '#cache_instance_key' do
      it 'returns instance_id for local instances' do
        provider.settings = { base_url: 'http://localhost:11434' }
        expect(provider.cache_instance_key).to eq('default')
      end

      it 'returns SHA256 prefix for remote instances' do
        provider.settings = { base_url: 'https://api.openai.com' }
        key = provider.cache_instance_key
        expect(key.length).to eq(12)
        expect(key).to match(/\A[0-9a-f]+\z/)
      end

      it 'produces deterministic keys for same URLs' do
        provider.settings = { base_url: 'https://api.openai.com' }
        key1 = provider.cache_instance_key
        key2 = provider.cache_instance_key
        expect(key1).to eq(key2)
      end
    end

    describe '#model_cache_get' do
      it 'returns nil when Legion::Cache is not defined' do
        expect(provider.model_cache_get('key')).to be_nil
      end
    end

    describe '#model_cache_set' do
      it 'returns nil when Legion::Cache is not defined' do
        expect(provider.model_cache_set('key', 'value', ttl: 60)).to be_nil
      end
    end

    describe '#model_cache_fetch' do
      it 'yields when Legion::Cache is not defined' do
        result = provider.model_cache_fetch('key', ttl: 60) { 'computed' }
        expect(result).to eq('computed')
      end
    end
  end
end
