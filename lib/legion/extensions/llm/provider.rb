# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Lightweight wrapper that lets a plain Hash behave like a Configuration
      # object, responding to method-style accessors (e.g. +config.api_key+).
      class HashConfig
        def initialize(hash)
          @data = hash.transform_keys(&:to_sym)
        end

        def to_h
          @data.dup
        end

        def respond_to_missing?(name, include_private = false)
          @data.key?(name.to_sym) || super
        end

        def method_missing(name, *args)
          key = name.to_sym
          if name.to_s.end_with?('=')
            @data[name.to_s.chomp('=').to_sym] = args.first
          elsif @data.key?(key)
            @data[key]
          end
        end
      end

      # Base class for LLM providers.
      class Provider
        include Streaming
        include Legion::Logging::Helper
        include Legion::Cache::Helper

        MODEL_DETAIL_CACHE_SCHEMA_VERSION = 2
        CAPABILITY_CONFIG_KEYS = %i[
          capabilities
          enable_completion
          enable_embedding
          enable_embeddings
          enable_streaming
          enable_tools
          enable_functions
          enable_function_calling
          enable_thinking
          enable_reasoning
          enable_vision
          enable_structured_output
          enable_moderation
          enable_image
          enable_images
          enable_image_generation
          enable_audio_transcription
          enable_audio_speech
          enable_audio_generation
          completion_flag
          embedding_flag
          embeddings_flag
          streaming_flag
          tool_flag
          tools_flag
          functions_flag
          function_calling_flag
          thinking_flag
          reasoning_flag
          vision_flag
          structured_output_flag
          moderation_flag
          image_flag
          images_flag
          image_generation_flag
          audio_transcription_flag
          audio_speech_flag
          audio_generation_flag
        ].freeze

        attr_reader :config, :connection

        def initialize(config)
          @config = config.is_a?(Hash) ? HashConfig.new(config) : config
          ensure_configured!
          @connection = Connection.new(self, @config)
        end

        def api_base
          raise NotImplementedError
        end

        def headers
          identity_headers
        end

        def identity_headers
          return {} unless defined?(Legion::Identity::Process) && Legion::Identity::Process.respond_to?(:identity_hash)

          id = Legion::Identity::Process.identity_hash
          hdrs = {
            'x-legion-identity-canonical-name' => id[:canonical_name].to_s,
            'x-legion-identity-trust' => id[:trust].to_s,
            'x-legion-identity-id' => id[:id].to_s,
            'x-legion-identity-kind' => id[:kind].to_s,
            'x-legion-identity-mode' => id[:mode].to_s,
            'x-legion-identity-source' => id[:source].to_s
          }
          hdrs['x-legion-identity-db-principal-id'] = id[:db_principal_id].to_s if id[:db_principal_id]
          hdrs['x-legion-identity-db-identity-id']  = id[:db_identity_id].to_s if id[:db_identity_id]
          hdrs
        rescue StandardError
          {}
        end

        def slug
          self.class.slug
        end

        def name
          self.class.name
        end

        def capabilities
          self.class.capabilities
        end

        def configuration_requirements
          self.class.configuration_requirements
        end

        # rubocop:disable Metrics/ParameterLists
        def chat(messages:, model:, tools: [], temperature: nil, params: {}, headers: {}, schema: nil, thinking: nil,
                 tool_prefs: nil)
          complete(messages, tools:, temperature:, model:, params:, headers:, schema:, thinking:, tool_prefs:)
        end

        def stream_chat(messages:, model:, tools: [], temperature: nil, params: {}, headers: {}, schema: nil,
                        thinking: nil, tool_prefs: nil, &)
          complete(messages, tools:, temperature:, model:, params:, headers:, schema:, thinking:, tool_prefs:, &)
        end

        def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil,
                     tool_prefs: nil, &)
          enforce_model_allowed!(model)
          normalized_temperature = maybe_normalize_temperature(temperature, model)
          log_provider_request(
            messages: messages,
            tools: tools,
            temperature: temperature,
            normalized_temperature: normalized_temperature,
            model: model,
            params: params,
            headers: headers,
            schema: schema,
            thinking: thinking,
            tool_prefs: tool_prefs,
            streaming: block_given?
          )

          payload = Utils.deep_merge(
            render_payload(
              messages,
              tools: tools,
              tool_prefs: tool_prefs,
              temperature: normalized_temperature,
              model: model,
              stream: block_given?,
              schema: schema,
              thinking: thinking
            ),
            params
          )

          if block_given?
            stream_response @connection, payload, headers, &
          else
            sync_response @connection, payload, headers
          end
        end
        # rubocop:enable Metrics/ParameterLists

        def list_models(live: false, **filters)
          _ = [live, filters]
          response = @connection.get models_url
          parse_list_models_response response, slug, capabilities
        end

        def discover_offerings(live: false, raise_on_unreachable: false, **filters)
          return filter_cached_offerings(Array(@cached_offerings), filters) unless live

          provider_health = health(live:)
          @cached_offerings = Array(list_models(live:, **filters)).filter_map do |model|
            publish_discovered_model_to_registry(model, provider_health:, live:)
            next unless model_matches_filters?(model, filters)
            next unless model_allowed?(model.id)

            log.debug("[#{slug}] instance=#{provider_instance_id} action=model_discovered model=#{model.id} family=#{model.family}")
            offering_from_model(model, health: provider_health)
          end
          log.info("[#{slug}] instance=#{provider_instance_id} action=discover_complete model_count=#{Array(@cached_offerings).size}")
          @cached_offerings
        rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
          log.warn("[#{slug}] instance=#{provider_instance_id} unreachable: #{e.message}")
          raise if raise_on_unreachable

          []
        end

        def publish_discovered_model_to_registry(model, provider_health:, live:)
          publisher = discovery_registry_publisher
          return unless publisher.respond_to?(:publish_models_async)

          publisher.publish_models_async([model], readiness: discovery_registry_readiness(provider_health, live:))
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.publish_discovered_model')
        end

        def discovery_registry_publisher
          return unless self.class.respond_to?(:registry_publisher)

          self.class.registry_publisher
        rescue StandardError
          nil
        end

        def discovery_registry_readiness(provider_health, live:)
          {
            provider: slug.to_sym,
            configured: configured?,
            ready: provider_health[:ready] == true,
            live: live,
            health: provider_health
          }
        end

        def health(live: false)
          readiness_data = readiness(live:)
          raw_health = readiness_data[:health] || readiness_data['health'] || {}
          status = health_status(readiness_data, raw_health)
          latency_ms = (raw_health[:latency_ms] || raw_health['latency_ms'] if raw_health.is_a?(Hash))
          {
            provider: slug.to_sym,
            instance_id: provider_instance_id,
            status:,
            ready: readiness_data[:ready] == true || readiness_data['ready'] == true,
            circuit_state: status == 'healthy' ? 'closed' : 'open',
            latency_ms: latency_ms,
            raw: raw_health
          }.compact
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.health')
          {
            provider: slug.to_sym,
            instance_id: provider_instance_id,
            status: 'unhealthy',
            ready: false,
            circuit_state: 'open',
            error: e.class.name,
            message: e.message
          }
        end

        def embed(text:, model:, dimensions: nil, params: {}, headers: {})
          enforce_model_allowed!(model)
          payload = Utils.deep_merge(render_embedding_payload(text, model:, dimensions:), params)
          response = @connection.post(embedding_url(model:), payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
          end
          parse_embedding_response(response, model:, text:)
        end

        def moderate(input, model:)
          enforce_model_allowed!(model)
          payload = render_moderation_payload(input, model:)
          response = @connection.post moderation_url, payload
          parse_moderation_response(response, model:)
        end

        def paint(prompt, model:, size:, with: nil, mask: nil, params: {}) # rubocop:disable Metrics/ParameterLists
          enforce_model_allowed!(model)
          validate_paint_inputs!(with:, mask:)
          payload = render_image_payload(prompt, model:, size:, with:, mask:, params:)
          response = @connection.post images_url(with:, mask:), payload
          parse_image_response(response, model:)
        end

        def image(prompt:, model:, size:, with: nil, mask: nil, params: {}) # rubocop:disable Metrics/ParameterLists
          paint(prompt, model:, size:, with:, mask:, params:)
        end

        def count_tokens(messages:, model:, params: {})
          _ = [model, params]
          Array(messages).sum do |message|
            content = message.respond_to?(:content) ? message.content : message[:content] || message['content']
            estimate_text_tokens(content)
          end
        end

        def transcribe(audio_file, model:, language:, **)
          file_part = build_audio_file_part(audio_file)
          payload = render_transcription_payload(file_part, model:, language:, **)
          response = @connection.post transcription_url, payload
          parse_transcription_response(response, model:)
        end

        def configured?
          configuration_requirements.all? { |req| @config.send(req) }
        end

        def cache_enabled?
          explicit = config.llm_cache_enabled if config.respond_to?(:llm_cache_enabled)

          unless explicit.nil?
            log.debug { "[#{slug}] cache_enabled? source=per_provider value=#{explicit}" }
            return explicit == true
          end

          global = global_prompt_caching_enabled?
          log.debug { "[#{slug}] cache_enabled? source=global value=#{global}" }
          global
        end

        def cache_control_prefix_tokens
          if config.respond_to?(:cache_control_prefix_tokens) && config.cache_control_prefix_tokens
            config.cache_control_prefix_tokens
          else
            4
          end
        end

        def local?
          self.class.local?
        end

        def remote?
          self.class.remote?
        end

        def assume_models_exist?
          self.class.assume_models_exist?
        end

        def readiness(live: false)
          metadata = {
            provider: slug.to_sym,
            name: name,
            configured: configured?,
            ready: configured?,
            local: local?,
            remote: remote?,
            api_base: api_base,
            endpoints: endpoint_manifest,
            live: live
          }

          return metadata.merge(health: { checked: false }) unless live && metadata[:endpoints][:health]

          response = @connection.get(metadata[:endpoints][:health])
          metadata.merge(ready: configured? && health_ready?(response.body), health: response.body)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.readiness')
          metadata.merge(ready: false, health: { error: e.class.name, message: e.message })
        end

        def endpoint_manifest
          endpoint_methods.each_with_object({}) do |(key, method_name), result|
            next unless respond_to?(method_name)

            value = public_send(method_name)
            result[key] = value unless value.nil?
          rescue ArgumentError, NotImplementedError
            next
          end
        end

        def parse_error(response)
          return if response.body.empty?

          body = try_parse_json(response.body)
          case body
          when Hash
            error = body['error']
            return error if error.is_a?(String)

            body.dig('error', 'message')
          when Array
            body.map do |part|
              error = part['error']
              error.is_a?(String) ? error : part.dig('error', 'message')
            end.join('. ')
          when String
            body[/"message"\s*:\s*"([^"]{1,500})/, 1] || body
          else
            body
          end
        end

        def format_messages(messages)
          messages.map do |msg|
            {
              role: msg.role.to_s,
              content: msg.content
            }
          end
        end

        def format_tool_calls(_tool_calls)
          nil
        end

        def parse_tool_calls(_tool_calls)
          nil
        end

        # ── Model allow-list / deny-list filtering ────────────────────────

        # Resolve model_whitelist with specificity cascade:
        # 1. Instance-level  (config.model_whitelist — extensions.llm.<provider>.instances.<id>.model_whitelist)
        # 2. Provider-level  (extensions.llm.<provider>.model_whitelist)
        # 3. Global          (extensions.llm.model_whitelist)
        # Returns the first non-nil, non-empty value found.
        def model_whitelist
          wl = config.model_whitelist if config.respond_to?(:model_whitelist)
          wl ||= instance_setting(:model_whitelist)
          wl ||= runtime_provider_setting(:model_whitelist)
          wl ||= global_llm_setting(:model_whitelist)
          Array(wl).map { |p| p.to_s.downcase }
        end

        # Resolve model_blacklist with the same specificity cascade as model_whitelist.
        def model_blacklist
          bl = config.model_blacklist if config.respond_to?(:model_blacklist)
          bl ||= instance_setting(:model_blacklist)
          bl ||= runtime_provider_setting(:model_blacklist)
          bl ||= global_llm_setting(:model_blacklist)
          Array(bl).map { |p| p.to_s.downcase }
        end

        # Pull a setting from the instance-level settings hash (if available),
        # distinct from the config object which is a HashConfig wrapper.
        def instance_setting(key)
          config_hash =
            if instance_variable_defined?(:@settings)
              @settings
            elsif respond_to?(:settings)
              settings
            else
              config
            end
          config_hash = config_hash.to_h if config_hash.respond_to?(:to_h)
          config_hash.is_a?(Hash) ? (config_hash[key] || config_hash[key.to_s]) : nil
        end

        # Provider-level setting: extensions.llm.<provider>.<key>
        def runtime_provider_setting(key)
          return nil unless defined?(Legion::Settings)

          ext = Legion::Settings[:extensions]
          return nil unless ext.is_a?(Hash) && ext[:llm].is_a?(Hash)

          provider_key = self.class.respond_to?(:slug) ? self.class.slug.to_sym : nil
          return nil unless provider_key

          provider_conf = ext[:llm][provider_key]
          provider_conf.is_a?(Hash) ? provider_conf[key] : nil
        rescue StandardError
          nil
        end

        # Global LLM setting: extensions.llm.<key> (lowest specificity)
        def global_llm_setting(key)
          return nil unless defined?(Legion::Settings)

          llm_conf = Legion::Settings.dig(:extensions, :llm)
          llm_conf.is_a?(Hash) ? llm_conf[key] : nil
        rescue StandardError
          nil
        end

        def model_allowed?(model_name)
          wl = model_whitelist
          bl = model_blacklist
          allowed = self.class.policy_allows?(model_name, whitelist: wl, blacklist: bl)

          unless allowed
            reason_parts = []
            reason_parts << 'whitelist' if wl.any?
            reason_parts << 'blacklist' if bl.any?
            reason_str = reason_parts.empty? ? 'policy' : reason_parts.join(',')
            policy_src = if wl.any?
                           "wl=[#{wl.first(5).join(',')}#{',...' if wl.size > 5}]"
                         else
                           'no-whitelist'
                         end
            log.debug("[#{self.class.slug}] action=model_rejected name=#{model_name} reason=#{reason_str} #{policy_src}")
          end

          allowed
        end

        # Single source of truth for model-policy matching, usable both at runtime
        # (instance #model_allowed?) and at instance-config build time (provider
        # extensions choosing a default_model that does not violate the policy).
        # Substring, case-insensitive: a whitelist permits models containing any
        # pattern; a blacklist denies models containing any pattern; whitelist is
        # applied before blacklist. Empty list = no restriction from that side.
        def self.policy_allows?(model_name, whitelist: [], blacklist: [])
          name = model_name.to_s.downcase
          wl = Array(whitelist).map { |p| p.to_s.downcase }
          bl = Array(blacklist).map { |p| p.to_s.downcase }

          return false if wl.any? && wl.none? { |p| name.include?(p) }
          return false if bl.any? && bl.any? { |p| name.include?(p) }

          true
        end

        # Effective whitelist/blacklist for an instance config at build time
        # (before provider instance exists). Same specificity cascade:
        # 1. Per-instance  (config hash — extensions.llm.<provider>.instances.<id>.model_whitelist)
        # 2. Provider-level (extensions.llm.<provider>.model_whitelist)
        # 3. Global        (extensions.llm.model_whitelist)
        def self.model_policy(config, provider_family)
          cfg = config.is_a?(Hash) ? config : {}
          provider_conf = CredentialSources.setting(:extensions, :llm, provider_family)
          provider_conf = {} unless provider_conf.is_a?(Hash)
          global_conf = (::Legion::Settings.dig(:extensions, :llm) if defined?(::Legion::Settings))
          global_conf = {} unless global_conf.is_a?(Hash)

          {
            whitelist: resolve_policy_value(cfg, provider_conf, global_conf, :model_whitelist),
            blacklist: resolve_policy_value(cfg, provider_conf, global_conf, :model_blacklist)
          }
        end

        # Resolve a single policy value with instance > provider > global precedence.
        def self.resolve_policy_value(cfg, provider_conf, global_conf, key)
          # Instance-level
          val = cfg[key] || cfg[key.to_s]
          return val if val && !val.to_s.empty? && (val.is_a?(Array) ? val.any? : true)

          # Provider-level
          val = provider_conf[key] || provider_conf[key.to_s]
          return val if val && !val.to_s.empty? && (val.is_a?(Array) ? val.any? : true)

          # Global
          global_conf[key] || global_conf[key.to_s]
        end

        # Choose a default_model that never violates the model policy: prefer an
        # explicitly-configured default when permitted; else a provider fallback when
        # permitted; else nil, so routing resolves an allowed discovered model rather
        # than forcing a policy-forbidden default. Keeps a whitelist/blacklist
        # authoritative over any hardcoded provider default.
        def self.policy_safe_default_model(configured:, fallback:, whitelist: [], blacklist: [])
          return configured if configured && !configured.to_s.empty? &&
                               policy_allows?(configured, whitelist:, blacklist:)
          return fallback if fallback && !fallback.to_s.empty? &&
                             policy_allows?(fallback, whitelist:, blacklist:)

          nil
        end

        # Compliance guard: refuse to dispatch any request for a model excluded by
        # the configured model_whitelist / model_blacklist. Invoked at every
        # dispatch entry point (the last line before the model API call) so a
        # denied model can never reach a provider API, regardless of caller. Fail
        # closed — raises rather than silently routing elsewhere.
        def enforce_model_allowed!(model_name)
          return if model_allowed?(model_name)

          log.warn("[#{slug}] action=model_denied model=#{model_name} instance=#{provider_instance_id} " \
                   'reason=model_whitelist_or_blacklist')
          raise ModelNotAllowedError.new(model: model_name, provider: slug)
        end

        # ── Offering defaults ─────────────────────────────────────────────

        def offering_transport
          config.respond_to?(:transport) ? config.transport : self.class.default_transport
        end

        def offering_tier
          config.respond_to?(:tier) ? config.tier : self.class.default_tier
        end

        # ── Multi-host base_url resolution ────────────────────────────────

        def resolve_base_url
          urls = Array(config_base_url)
          return nil if urls.empty?

          @resolve_base_url ||= find_reachable_url(urls) || normalize_url(urls.first)
        end

        def config_base_url
          respond_to?(:settings) ? settings[:base_url] : nil
        end

        def normalize_url(url)
          raw = url.to_s.strip
          return raw if raw.match?(%r{^https?://})

          scheme = tls_enabled? ? 'https' : 'http'
          "#{scheme}://#{raw}"
        end

        def find_reachable_url(urls)
          urls.each do |url|
            full = normalize_url(url)
            return full if url_reachable?(full)
          end
          nil
        end

        def strip_scheme(url)
          url.to_s.sub(%r{^https?://}, '')
        end

        def url_reachable?(url)
          require 'uri'
          require 'socket'
          uri = URI.parse(url)
          Socket.tcp(uri.host, uri.port, connect_timeout: 1).close
          true
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.url_reachable', url:)
          false
        end

        def tls_enabled?
          tls = respond_to?(:settings) ? settings[:tls] : nil
          tls.is_a?(Hash) && tls[:enabled] == true
        end

        # ── Cache helpers with local/shared tier selection ────────────────

        def cache_local_instance?
          Array(config_base_url).any? do |url|
            host = url.to_s.downcase
            host.include?('localhost') || host.include?('127.0.0.1') || host.include?('::1')
          end
        end

        def model_cache_get(key)
          return nil unless defined?(Legion::Cache)

          cache_local_instance? ? local_cache_get(key) : cache_get(key)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.model_cache_get', key:)
          nil
        end

        def model_detail(model_name)
          key = model_detail_cache_key(model_name)
          cached = cache_get(key)
          return cached if cached

          result = fetch_model_detail(model_name)
          cache_set(key, result, ttl: 86_400) if result
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.model_detail',
                              model: model_name)
          nil
        end

        # Override in subclasses to make a live API call for model detail.
        # Must return a Hash with symbol keys (e.g. { context_window: 128000 }).
        def fetch_model_detail(_model_name)
          nil
        end

        def cache_instance_key
          if cache_local_instance?
            (respond_to?(:instance_id) ? instance_id : :default).to_s
          else
            require 'digest'
            urls = Array(config_base_url).map { |u| strip_scheme(u).downcase.chomp('/') }.sort
            Digest::SHA256.hexdigest(urls.join('|'))[0, 12]
          end
        end

        def provider_instance_id
          return config.instance_id.to_sym if config.respond_to?(:instance_id) && config.instance_id

          :default
        end

        class << self
          def name
            to_s.split('::').last
          end

          def slug
            name.downcase
          end

          def capabilities
            nil
          end

          def configuration_requirements
            []
          end

          def configuration_options
            []
          end

          def default_transport
            :http
          end

          def default_tier
            :frontier
          end

          def local?
            false
          end

          def remote?
            !local?
          end

          def assume_models_exist?
            false
          end

          def resolve_model_id(model_id, config: nil) # rubocop:disable Lint/UnusedMethodArgument
            model_id
          end

          def configured?(config)
            configuration_requirements.all? { |req| config.send(req) }
          end
        end

        private

        def provider_capability_config
          return {} unless defined?(Legion::Extensions::Llm::CredentialSources)

          raw = Legion::Extensions::Llm::CredentialSources.setting(:extensions, :llm, slug.to_sym)
          return {} unless raw.respond_to?(:to_h)

          raw.to_h.except(:instances, 'instances')
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: "#{slug}.provider_capability_config")
          {}
        end

        def instance_capability_config
          extract_capability_config(config)
        end

        def model_capability_config(model_id)
          provider_models = provider_capability_models
          instance_models = extract_models_config(config)
          provider_override = provider_models[model_id.to_s] || provider_models[model_id.to_sym] || {}
          instance_override = instance_models[model_id.to_s] || instance_models[model_id.to_sym] || {}
          provider_override.to_h.merge(instance_override.to_h)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: "#{slug}.model_capability_config")
          {}
        end

        def global_prompt_caching_enabled?
          return false unless defined?(Legion::Settings)

          Legion::Settings.dig(:llm, :prompt_caching, :enabled) == true
        rescue StandardError
          false
        end

        def model_detail_cache_key(model_name)
          tier = offering_tier
          instance_key = cache_instance_key
          cred_fp = credential_cache_fragment
          key_parts = [
            'model_info',
            "schema#{MODEL_DETAIL_CACHE_SCHEMA_VERSION}",
            tier, slug, instance_key, cred_fp, model_name
          ].compact
          key_parts.join('.')
        end

        def credential_cache_fragment
          return nil if cache_local_instance?

          cred = config.respond_to?(:bearer_token) && config.bearer_token
          cred ||= config.respond_to?(:api_key) && config.api_key
          cred ||= config.respond_to?(:bedrock_access_key_id) && config.bedrock_access_key_id
          return nil unless cred

          require 'digest'
          Digest::SHA256.hexdigest(cred.to_s)[0, 8]
        end

        def validate_paint_inputs!(with:, mask:)
          return if with.nil? && mask.nil?

          raise UnsupportedAttachmentError, "#{name} does not support image references in paint"
        end

        def extract_capability_config(source)
          return {} unless source

          CAPABILITY_CONFIG_KEYS.each_with_object({}) do |key, result|
            next unless source.respond_to?(key)

            value = source.public_send(key)
            result[key] = value unless value.nil?
          rescue StandardError
            next
          end
        end

        def extract_models_config(source)
          return {} unless source.respond_to?(:models)

          models = source.models
          models.respond_to?(:to_h) ? models.to_h : {}
        rescue StandardError
          {}
        end

        def provider_capability_models
          config = provider_capability_config
          models = config[:models] || config['models']
          models.respond_to?(:to_h) ? models.to_h : {}
        end

        def offering_from_model(model, health: {})
          capability_sources = Array(model.capabilities).to_h do |cap|
            [cap.to_sym, { value: true, source: :model_metadata }]
          end

          Routing::ModelOffering.new(
            provider_family: slug.to_sym,
            provider_instance: model.instance || provider_instance_id,
            transport: offering_transport,
            tier: offering_tier,
            model: model.id,
            canonical_model_alias: model.name,
            model_family: model.family,
            usage_type: offering_usage_type(model),
            capabilities: model.capabilities,
            capability_sources: capability_sources,
            limits: offering_limits(model),
            health:,
            metadata: offering_metadata(model)
          )
        end

        def offering_usage_type(model)
          model.embedding? ? :embedding : :inference
        end

        def offering_limits(model)
          {
            context_window: model.context_length,
            max_output_tokens: model.max_output_tokens
          }.compact
        end

        def offering_metadata(model)
          {
            raw_model: model.id,
            parameter_count: model.parameter_count,
            parameter_size: model.parameter_size,
            quantization: model.quantization,
            size_bytes: model.size_bytes,
            modalities_input: model.modalities_input,
            modalities_output: model.modalities_output
          }.merge(model.metadata || {}).compact
        end

        def model_matches_filters?(model, filters)
          return true if filters.empty?

          filters.all? do |key, value|
            blank_filter_value?(value) || model_matches_filter?(model, key, value)
          end
        end

        def blank_filter_value?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end

        def model_matches_filter?(model, key, value)
          case key.to_sym
          when :capability, :capabilities
            Array(value).all? { |capability| model.supports?(capability) }
          when :type, :usage_type, :purpose
            offering_usage_type(model).to_s == value.to_s || model.type.to_s == value.to_s
          when :model, :id, :name
            [model.id, model.name].map(&:to_s).include?(value.to_s)
          when :instance, :instance_id, :provider_instance
            provider_instance_id.to_s == value.to_s || model.instance.to_s == value.to_s
          else
            true
          end
        end

        def filter_cached_offerings(offerings, filters)
          return offerings if filters.empty?

          offerings.select do |offering|
            filters.all? do |key, value|
              blank_filter_value?(value) || offering_matches_filter?(offering, key, value)
            end
          end
        end

        def offering_matches_filter?(offering, key, value)
          case key.to_sym
          when :provider, :provider_family
            offering.provider_family.to_s == value.to_s
          when :capability, :capabilities
            Array(value).all? { |capability| offering.supports?(capability) }
          when :type, :usage_type, :purpose
            offering.usage_type.to_s == value.to_s
          when :model, :id, :name
            [offering.model, offering.canonical_model_alias].compact.map(&:to_s).include?(value.to_s)
          when :instance, :instance_id, :provider_instance
            [offering.provider_instance, offering.instance_id].compact.map(&:to_s).include?(value.to_s)
          else
            true
          end
        end

        def health_status(readiness_data, raw_health)
          return 'healthy' if readiness_data[:ready] == true || readiness_data['ready'] == true

          status = if raw_health.is_a?(Hash)
                     raw_health[:status] || raw_health['status'] || raw_health[:state] || raw_health['state']
                   else
                     raw_health
                   end
          return 'healthy' if %w[ok ready healthy running].include?(status.to_s.downcase)

          'unhealthy'
        end

        def estimate_text_tokens(content)
          text = case content
                 when Content
                   [content.text, *content.attachments.map(&:to_s)].compact.join(' ')
                 when Array
                   content.map do |part|
                     part.respond_to?(:[]) ? part[:text] || part['text'] || part.to_s : part.to_s
                   end.join(' ')
                 else
                   content.to_s
                 end
          [(text.length / 4.0).ceil, 1].max
        end

        def build_audio_file_part(file_path)
          expanded_path = File.expand_path(file_path)
          mime_type = Marcel::MimeType.for(Pathname.new(expanded_path))

          Faraday::Multipart::FilePart.new(
            expanded_path,
            mime_type,
            File.basename(expanded_path)
          )
        end

        def try_parse_json(maybe_json)
          return maybe_json unless maybe_json.is_a?(String)

          Legion::JSON.parse(maybe_json, symbolize_names: false)
        rescue Legion::JSON::ParseError
          maybe_json
        end

        def ensure_configured!
          missing = configuration_requirements.reject { |req| @config.send(req) }
          return if missing.empty?

          raise ConfigurationError, "Missing configuration for #{name}: #{missing.join(', ')}"
        end

        def maybe_normalize_temperature(temperature, _model)
          temperature
        end

        def log_provider_request(context)
          log.debug do
            "Preparing provider completion: provider=#{slug} model=#{debug_model_id(context[:model])} " \
              "streaming=#{context[:streaming]} messages=#{Array(context[:messages]).size} " \
              "tools=#{debug_tool_names(context[:tools]).inspect} " \
              "temperature=#{context[:temperature].inspect} " \
              "normalized_temperature=#{context[:normalized_temperature].inspect} " \
              "param_keys=#{debug_hash_keys(context[:params]).inspect} " \
              "header_keys=#{debug_hash_keys(context[:headers]).inspect} " \
              "schema=#{debug_value_summary(context[:schema])} " \
              "thinking=#{debug_value_summary(context[:thinking])} " \
              "tool_prefs=#{debug_value_summary(context[:tool_prefs])}"
          end
        end

        def debug_model_id(model)
          return model.id if model.respond_to?(:id)

          model
        end

        def debug_tool_names(tools)
          tool_definitions = tools.is_a?(Hash) ? tools.values : Array(tools)

          tool_definitions.filter_map do |tool|
            if tool.respond_to?(:name)
              tool.name
            elsif tool.is_a?(Hash)
              tool[:name] || tool['name']
            else
              tool.class.name
            end
          end
        end

        def debug_hash_keys(value)
          value.respond_to?(:keys) ? value.keys.map(&:to_s).sort : []
        end

        def debug_value_summary(value)
          return 'nil' if value.nil?
          return "#{value.class}(keys=#{debug_hash_keys(value).inspect})" if value.respond_to?(:keys)
          return "#{value.class}(size=#{value.size})" if value.respond_to?(:size)

          value.class.name
        end

        def endpoint_methods
          {
            completion: :completion_url,
            stream: :stream_url,
            models: :models_url,
            embeddings: :embedding_url,
            moderation: :moderation_url,
            images: :images_url,
            transcription: :transcription_url,
            health: :health_url,
            version: :version_url
          }
        end

        def health_ready?(body)
          return body unless body.is_a?(Hash)

          status = body['status'] || body[:status] || body['state'] || body[:state]
          return true if status.nil?

          %w[ok ready healthy running].include?(status.to_s.downcase)
        end

        def sync_response(connection, payload, additional_headers = {})
          response = connection.post completion_url, payload do |req|
            req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
          end
          parse_completion_response response
        end
      end
    end
  end
end
