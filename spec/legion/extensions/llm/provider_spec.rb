# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Provider do
  describe 'Hash config support' do
    let(:provider_class) do
      Class.new(described_class) do
        def api_base = 'https://test.invalid'
      end
    end

    it 'accepts a plain Hash and wraps it so method-style access works' do
      provider = provider_class.new({ request_timeout: 60, max_retries: 2,
                                      retry_interval: 0, retry_backoff_factor: 0,
                                      retry_interval_randomness: 0,
                                      anthropic_api_key: 'sk-test-123' })
      expect(provider.config.anthropic_api_key).to eq('sk-test-123')
      expect(provider.config.request_timeout).to eq(60)
    end

    it 'converts string keys to symbols' do
      provider = provider_class.new({ 'request_timeout' => 120, 'max_retries' => 1,
                                      'retry_interval' => 0, 'retry_backoff_factor' => 0,
                                      'retry_interval_randomness' => 0,
                                      'some_key' => 'value' })
      expect(provider.config.some_key).to eq('value')
      expect(provider.config.request_timeout).to eq(120)
    end

    it 'returns nil for missing keys instead of raising' do
      provider = provider_class.new({ request_timeout: 30, max_retries: 0,
                                      retry_interval: 0, retry_backoff_factor: 0,
                                      retry_interval_randomness: 0 })
      expect(provider.config.nonexistent_key).to be_nil
    end

    it 'supports respond_to_missing? for present keys' do
      provider = provider_class.new({ request_timeout: 30, max_retries: 0,
                                      retry_interval: 0, retry_backoff_factor: 0,
                                      retry_interval_randomness: 0,
                                      ollama_api_base: 'http://localhost:11434' })
      expect(provider.config.respond_to?(:ollama_api_base)).to be true
      expect(provider.config.respond_to?(:nonexistent_key)).to be false
    end

    it 'supports setter methods' do
      provider = provider_class.new({ request_timeout: 30, max_retries: 0,
                                      retry_interval: 0, retry_backoff_factor: 0,
                                      retry_interval_randomness: 0 })
      provider.config.new_value = 'hello'
      expect(provider.config.new_value).to eq('hello')
    end

    it 'still works with a Configuration object' do
      provider = provider_class.new(Legion::Extensions::Llm.config)
      expect(provider.config).to be_a(Legion::Extensions::Llm::Configuration)
      expect(provider.config.request_timeout).to be_a(Numeric)
    end
  end

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

  describe 'canonical provider contract' do
    let(:model) do
      Legion::Extensions::Llm::Model::Info.new(
        id: 'test-model',
        provider: :contract,
        instance: :primary,
        capabilities: %i[completion streaming tools],
        context_length: 8192,
        metadata: { max_output_tokens: 2048 }
      )
    end

    let(:provider_class) do
      model_info = model
      Class.new(described_class) do
        def self.name = 'Provider'

        define_method(:api_base) { 'https://contract.invalid' }
        define_method(:models_url) { '/v1/models' }
        attr_reader :list_model_calls

        define_method(:list_models) do |live: false, **filters|
          @list_model_calls ||= []
          @list_model_calls << { live: live, filters: filters }
          [model_info]
        end

        def render_payload(_messages, **)
          {}
        end

        def parse_completion_response(_response)
          Legion::Extensions::Llm::Message.new(role: :assistant, content: 'ok')
        end
      end
    end

    let(:provider) do
      provider_class.new({ request_timeout: 30, max_retries: 0,
                           retry_interval: 0, retry_backoff_factor: 0,
                           retry_interval_randomness: 0,
                           instance_id: :primary })
    end

    it 'exposes a canonical chat alias over complete' do
      allow(provider).to receive(:complete).and_return('ok')

      expect(provider.chat(messages: [], model: model)).to eq('ok')
      expect(provider).to have_received(:complete).with(
        [], tools: [], temperature: nil, model: model, params: {}, headers: {},
            schema: nil, thinking: nil, tool_prefs: nil
      )
    end

    it 'exposes a canonical stream_chat alias over complete' do
      seen = []
      allow(provider).to receive(:complete) { |_messages, **_opts, &block| block.call('chunk') }

      provider.stream_chat(messages: [], model: model) { |chunk| seen << chunk }

      expect(seen).to eq(['chunk'])
    end

    it 'converts live list_models results into model offerings' do
      offerings = provider.discover_offerings(live: true)
      offering = offerings.first

      expect(offerings.size).to eq(1)
      expect(offering.provider_family).to eq(:provider)
      expect(offering.provider_instance).to eq(:primary)
      expect(offering.model).to eq('test-model')
      expect(offering.usage_type).to eq(:inference)
      expect(offering.capabilities).to include(:completion, :streaming, :tools)
      expect(offering.context_window).to eq(8192)
    end

    it 'passes live discovery filters through to list_models' do
      provider.discover_offerings(live: true, capability: :tools, instance: :primary)

      expect(provider.list_model_calls).to include(
        live: true,
        filters: { capability: :tools, instance: :primary }
      )
    end

    it 'filters generated offerings by capability and instance' do
      provider.discover_offerings(live: true)

      expect(provider.discover_offerings(capability: :tools, instance: :primary)).not_to be_empty
      expect(provider.discover_offerings(capability: :embedding)).to be_empty
      expect(provider.discover_offerings(instance: :other)).to be_empty
    end

    it 'does not perform live discovery for uncached non-live offerings reads' do
      allow(provider).to receive(:list_models).and_raise('unexpected live discovery')

      expect(provider.discover_offerings).to eq([])
      expect(provider).not_to have_received(:list_models)
    end

    it 'serves non-live offerings reads from the live discovery cache' do
      provider.discover_offerings(live: true)
      allow(provider).to receive(:list_models).and_raise('unexpected live discovery')

      expect(provider.discover_offerings(capability: :tools, instance: :primary)).not_to be_empty
    end

    it 'returns normalized health metadata' do
      expect(provider.health).to include(
        provider: :provider,
        instance_id: :primary,
        status: 'healthy',
        ready: true,
        circuit_state: 'closed'
      )
    end

    it 'provides a deterministic token estimate fallback' do
      expect(provider.count_tokens(messages: [{ content: 'hello world' }], model: model)).to be >= 1
    end

    it 'summarizes hash-backed tools for debug logging' do
      tools = {
        current: { name: 'current' },
        legacy: { 'name' => 'legacy' }
      }

      expect(provider.send(:debug_tool_names, tools)).to eq(%w[current legacy])
    end

    it 'deep merges embedding params into the provider payload' do
      captured_payload = nil
      response = instance_double(Faraday::Response)
      connection = instance_double(Legion::Extensions::Llm::Connection)
      embedding_provider_class = Class.new(described_class) do
        def api_base = 'https://contract.invalid'
        def embedding_url(model:) = "/v1/#{model}/embeddings"

        def render_embedding_payload(text, model:, dimensions:)
          {
            model: model,
            input: text,
            options: {
              dimensions: dimensions,
              normalize: false
            }
          }
        end

        def parse_embedding_response(response, model:, text:)
          [response, model, text]
        end
      end
      embedding_provider = embedding_provider_class.new(provider.config)
      embedding_provider.instance_variable_set(:@connection, connection)

      allow(connection).to receive(:post) do |_url, payload, &_block|
        captured_payload = payload
        response
      end

      result = embedding_provider.embed(
        text: 'hello',
        model: 'embed-model',
        dimensions: 1024,
        params: {
          options: { normalize: true },
          encoding_format: 'float'
        }
      )

      expect(result).to eq([response, 'embed-model', 'hello'])
      expect(connection).to have_received(:post).with('/v1/embed-model/embeddings', kind_of(Hash))
      expect(captured_payload).to eq(
        model: 'embed-model',
        input: 'hello',
        options: {
          dimensions: 1024,
          normalize: true
        },
        encoding_format: 'float'
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

    describe '#model_detail' do
      it 'returns nil by default (no fetch_model_detail override)' do
        expect(provider.model_detail('test-model')).to be_nil
      end
    end
  end
end
