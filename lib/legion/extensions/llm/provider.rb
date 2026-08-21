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
        include StopReasonMapping
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
        HEALTHY_STATES = %w[ok ready healthy running].freeze

        attr_reader :config, :connection

        def initialize(config)
          @config = config.is_a?(Hash) ? HashConfig.new(config) : config
          ensure_configured!
          @connection = Connection.new(self, @config)
        end

        def disconnect
          @connection&.close
          @connection = nil
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
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.identity_headers')
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

        # N x N law — the dispatch boundary contract. Pipeline dispatch (direct
        # SelectionDispatch, fleet worker rehydration) delivers
        # Canonical::Message objects; provider callables are the canonical
        # boundary and must reject anything else LOUDLY. No coercion, no
        # hash tolerance, no fallback — a half-translated legacy shape here is
        # the defect class the N x N method exists to kill.
        def enforce_canonical_messages!(messages)
          Array(messages).each do |message|
            next if message.is_a?(Canonical::Message)

            raise ArgumentError,
                  "provider input must be Canonical::Message objects, got #{message.class} — " \
                  'non-canonical message shapes must not cross the dispatch boundary'
          end
          messages
        end

        # N x N law — the tools half of the dispatch boundary contract (H3).
        # Enforced HERE, once, like messages: a non-empty tools value must be
        # Hash<name, Canonical::ToolDefinition>. Hash-tolerant renderers and
        # legacy Lex::Llm::Tool values are the defect class this check kills —
        # the shared ToolSchema extractor already refuses them (04 §6).
        def enforce_canonical_tools!(tools)
          return tools if tools.nil? || tools.empty?

          unless tools.is_a?(::Hash)
            raise ArgumentError,
                  "provider tools must be Hash<name, Canonical::ToolDefinition>, got #{tools.class} — " \
                  'non-canonical tool shapes must not cross the dispatch boundary'
          end

          tools.each_value do |tool|
            next if tool.is_a?(Canonical::ToolDefinition)

            raise ArgumentError,
                  "provider tools values must be Canonical::ToolDefinition, got #{tool.class} — " \
                  'non-canonical tool shapes must not cross the dispatch boundary'
          end
          tools
        end

        # rubocop:disable Metrics/ParameterLists
        # The single completion funnel (05 O1/O2): chat/stream_chat are thin
        # delegates. Central enforcement — canonical input is checked HERE, once,
        # before any rendering; providers never re-implement the check (08 F2).
        # temperature lives only in Canonical::Params (05 O4).
        def chat(messages, model:, tools: [], params: nil, headers: {}, schema: nil, thinking: nil, tool_prefs: nil)
          complete(messages, tools:, model:, params:, headers:, schema:, thinking:, tool_prefs:)
        end

        def stream_chat(messages, model:, tools: [], params: nil, headers: {}, schema: nil,
                        thinking: nil, tool_prefs: nil, &)
          complete(messages, tools:, model:, params:, headers:, schema:, thinking:, tool_prefs:, &)
        end

        def complete(messages, model:, tools: [], params: nil, headers: {}, schema: nil, thinking: nil,
                     tool_prefs: nil, &)
          enforce_model_allowed!(model)
          enforce_canonical_messages!(messages)
          enforce_canonical_tools!(tools)
          log_provider_request(
            messages: messages,
            tools: tools,
            model: model,
            params: params,
            headers: headers,
            schema: schema,
            thinking: thinking,
            tool_prefs: tool_prefs,
            streaming: block_given?
          )

          payload = render_payload(
            messages,
            tools: tools,
            tool_prefs: tool_prefs,
            model: model,
            stream: block_given?,
            schema: schema,
            thinking: thinking,
            params: params
          )

          if block_given?
            stream_response @connection, payload, headers, model: model, &
          else
            sync_response @connection, payload, headers
          end
        end
        # rubocop:enable Metrics/ParameterLists

        # H5: the base read path is ALWAYS live (one HTTP fetch to
        # models_url) — it has no non-live view, so `live:` is accepted for
        # signature compatibility (REQUIRED_SIGNATURES) and has no effect
        # here. `filters` are applied to the parsed list: model/id/name match
        # the model id, instance the instance label, provider/provider_family
        # the provider; unknown keys pass (see filter_model_list).
        def list_models(live: false, **filters)
          _live = live
          models = parse_list_models_response(@connection.get(models_url), slug, capabilities)
          filter_model_list(models, filters)
        end

        # Read path (07 C5): serves the activated inventory offerings for this
        # provider instance from the SSOT registry snapshot. The legacy
        # ModelOffering production path is deleted; the per-gem writer is the
        # sole publication path. H5: this read path performs NO transport —
        # it is an in-memory snapshot lookup — so `live:` and
        # `raise_on_unreachable:` are accepted for signature compatibility
        # and have no effect here. `filters` select from the snapshot.
        def discover_offerings(live: false, raise_on_unreachable: false, **filters)
          _live = live
          _raise_on_unreachable = raise_on_unreachable
          instance_key = Inventory::Identity::InstanceKey.new(
            provider_family: slug.to_sym, instance_id: provider_instance_id
          )
          record = Inventory::Registry.snapshot.instance(instance_key: instance_key)
          offerings = record ? record.offerings_by_id.values : []
          filter_inventory_offerings(offerings, filters)
        end

        # Read-path filter over parsed model lists (H5): the same key
        # semantics as filter_inventory_offerings, matched against Model::Info.
        def filter_model_list(models, filters)
          return models if filters.empty?

          models.select do |model|
            filters.all? do |key, value|
              next true if value.nil? || (value.respond_to?(:empty?) && value.empty?)

              case key.to_sym
              when :model, :id, :name
                model.id.to_s == value.to_s
              when :instance, :instance_id, :provider_instance
                model.instance.to_s == value.to_s
              when :provider, :provider_family
                model.provider.to_s == value.to_s
              else
                true
              end
            end
          end
        end

        # Read-path filter over inventory offerings: model/id/name match the
        # offering model; instance/provider keys match the instance; unknown
        # keys pass.
        def filter_inventory_offerings(offerings, filters)
          return offerings if filters.empty?

          offerings.select do |offering|
            filters.all? do |key, value|
              next true if value.nil? || (value.respond_to?(:empty?) && value.empty?)

              inventory_offering_matches_filter?(offering, key, value)
            end
          end
        end

        def inventory_offering_matches_filter?(offering, key, value)
          case key.to_sym
          when :model, :id, :name
            offering.model.to_s == value.to_s
          when :instance, :instance_id, :provider_instance
            offering.instance_key.instance_id.to_s == value.to_s
          when :provider, :provider_family
            offering.instance_key.provider_family.to_s == value.to_s
          else
            true
          end
        end

        def health(live: false)
          readiness_data = readiness(live:)
          raw_health = readiness_data[:health] || readiness_data['health'] || {}
          status = healthy?(readiness_data, raw_health) ? 'healthy' : 'unhealthy'
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

        # The one health classifier (10 §1E): a readiness/health body is healthy
        # when ready is true, or the status/state names a healthy state. No
        # other implicit health (fail-closed — 0.8.x law).
        def healthy?(readiness_data, raw_health)
          return true if readiness_data.is_a?(Hash) && (readiness_data[:ready] == true || readiness_data['ready'] == true)

          status = if raw_health.is_a?(Hash)
                     raw_health[:status] || raw_health['status'] || raw_health[:state] || raw_health['state']
                   else
                     raw_health
                   end
          self.class::HEALTHY_STATES.include?(status.to_s.downcase)
        end

        def embed(text:, model:, dimensions: nil, params: nil, headers: {})
          enforce_model_allowed!(model)
          payload = render_embedding_payload(text, model:, dimensions:)
          payload = Utils.deep_merge(payload, params.to_h) if params
          response = @connection.post(embedding_url(model:), payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
          end
          parse_embedding_response(response, model:, text:)
        end

        def moderate(input:, model:)
          enforce_model_allowed!(model)
          unless input.is_a?(::String) || (input.is_a?(::Array) && input.all?(Canonical::Message))
            raise ArgumentError, "moderate input must be a String or Array<Canonical::Message>, got #{input.class}"
          end

          payload = render_moderation_payload(input, model:)
          response = @connection.post moderation_url, payload
          parse_moderation_response(response, model:)
        end

        def image(prompt:, model:, size:, with: nil, mask: nil, params: {}) # rubocop:disable Metrics/ParameterLists
          enforce_model_allowed!(model)
          validate_image_inputs!(with:, mask:)
          payload = render_image_payload(prompt, model:, size:, with:, mask:, params:)
          response = @connection.post images_url(with:, mask:), payload
          parse_image_response(response, model:)
        end

        def count_tokens(messages:, model:, params: nil)
          _ = [model, params]
          enforce_canonical_messages!(messages)
          Array(messages).sum do |message|
            estimate_text_tokens(message.content)
          end
        end

        def transcribe(audio_file, model:, language:, **)
          file_part = build_audio_file_part(audio_file)
          payload = render_transcription_payload(file_part, model:, language:, **)
          response = @connection.post transcription_url, payload
          parse_transcription_response(response, model:)
        end

        # Fail-loud base audio operations. Unsupported providers inherit these and
        # publish OperationEvidence(status: :unsupported) or :unknown; a provider
        # may publish :supported only when its Phase 2 conformance spec exercises
        # the actual callable path. Neither method reads configuration or infers a
        # model.
        def translate(audio_file, model:, language:, **provider_options)
          _ = [audio_file, model, language, provider_options]
          raise NotImplementedError, "#{self.class} does not implement translate"
        end

        def speak(text, model:, voice: nil, **provider_options)
          _ = [text, model, voice, provider_options]
          raise NotImplementedError, "#{self.class} does not implement speak"
        end

        # Runtime error-to-outcome normalization consumed by the common
        # classifier. The inherited base is deliberately conservative: raw 503,
        # Anthropic-style 529, ServiceUnavailableError, ServerError, and every
        # unrecognized error return :provider_error, never :instance_unavailable.
        # Provider PRs override only when their wire semantics supply stronger
        # evidence. The fallback reason is the bounded exception class name — never
        # a response body, credential, endpoint, or exception object. It is a base
        # method, not a REQUIRED_SIGNATURES reflection entry.
        def normalize_dispatch_error(error:)
          reason = error.class.name
          reason = 'UnknownError' if reason.nil? || reason.empty?
          Legion::Extensions::Llm::Routing::ProviderOutcome.new(
            kind: Legion::Extensions::Llm::Routing::ProviderOutcome.kind_for(error), reason: reason
          )
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
          metadata.merge(ready: configured? && healthy?(nil, response.body), health: response.body)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.readiness')
          metadata.merge(ready: false, health: { error: e.class.name, message: e.message })
        end

        def endpoint_manifest
          endpoint_methods.each_with_object({}) do |(key, method_name), result|
            next unless respond_to?(method_name)

            value = public_send(method_name)
            result[key] = value unless value.nil?
          rescue ArgumentError, NotImplementedError => e
            handle_exception(e, level: :debug, handled: true, operation: 'llm.provider.endpoint_manifest', method: method_name)
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
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.runtime_provider_setting', key:)
          nil
        end

        # Global LLM setting: extensions.llm.<key> (lowest specificity)
        def global_llm_setting(key)
          return nil unless defined?(Legion::Settings)

          llm_conf = Legion::Settings.dig(:extensions, :llm)
          llm_conf.is_a?(Hash) ? llm_conf[key] : nil
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.global_llm_setting', key:)
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

        # Single source of truth for model-policy matching, usable at runtime
        # (instance #model_allowed?). Substring, case-insensitive: a whitelist
        # permits models containing any pattern; a blacklist denies models
        # containing any pattern; whitelist is applied before blacklist.
        # Empty list = no restriction from that side.
        # Model identity for policy matching: the canonical id string. Model
        # objects (e.g. Model::Info) match by their #id — never by their
        # inspect string; bare strings pass through unchanged.
        def self.model_identity(model)
          candidate = model.respond_to?(:id) ? model.id : model
          candidate = model if candidate.nil?

          candidate.to_s
        end

        def self.policy_allows?(model_name, whitelist: [], blacklist: [])
          name = model_identity(model_name).downcase
          wl = Array(whitelist).map { |p| p.to_s.downcase }
          bl = Array(blacklist).map { |p| p.to_s.downcase }

          return false if wl.any? && wl.none? { |p| name.include?(p) }
          return false if bl.any? && bl.any? { |p| name.include?(p) }

          true
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
          Array(config_base_url).any? { |url| Utils.localhost_url?(url) }
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
          SettingsCascade.merge_model_scopes(
            provider_conf: provider_capability_config,
            instance_cfg: config.respond_to?(:to_h) ? config.to_h : {},
            model: model_id
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: "#{slug}.model_capability_config")
          {}
        end

        def global_prompt_caching_enabled?
          return false unless defined?(Legion::Settings)

          Legion::Settings.dig(:llm, :prompt_caching, :enabled) == true
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.global_prompt_caching')
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

        def validate_image_inputs!(with:, mask:)
          return if with.nil? && mask.nil?

          raise UnsupportedAttachmentError, "#{name} does not support image references in image"
        end

        def extract_capability_config(source)
          return {} unless source

          CAPABILITY_CONFIG_KEYS.each_with_object({}) do |key, result|
            next unless source.respond_to?(key)

            value = source.public_send(key)
            result[key] = value unless value.nil?
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: "#{slug}.extract_capability_config", key: key)
            next
          end
        end

        # Canonical content only (05 §2): String | ContentBlock |
        # Array<ContentBlock> | nil — one estimator code path.
        def estimate_text_tokens(content)
          text = case content
                 when String then content
                 when Canonical::ContentBlock
                   content.text.to_s
                 when Array
                   content.filter_map do |block|
                     block.is_a?(Canonical::ContentBlock) && block.text? ? block.text : nil
                   end.join(' ')
                 else
                   ''
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
        rescue Legion::JSON::ParseError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.provider.try_parse_json')
          maybe_json
        end

        def ensure_configured!
          missing = configuration_requirements.reject { |req| @config.send(req) }
          return if missing.empty?

          raise ConfigurationError, "Missing configuration for #{name}: #{missing.join(', ')}"
        end

        # One home for temperature (05 O4): it lives in Canonical::Params.
        # Provider renderers that need per-model normalization read
        # params.temperature and call this hook from their render path.
        def maybe_normalize_temperature(params)
          params&.temperature
        end

        def log_provider_request(context)
          log.debug do
            "Preparing provider completion: provider=#{slug} model=#{debug_model_id(context[:model])} " \
              "streaming=#{context[:streaming]} messages=#{Array(context[:messages]).size} " \
              "tools=#{debug_tool_names(context[:tools]).inspect} " \
              "params=#{debug_value_summary(context[:params])} " \
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

        # H3: the funnel enforces Canonical::ToolDefinition before logging,
        # so the Hash-tolerance branch is deleted — only canonical names or
        # a class name for anything that slips a direct private call.
        def debug_tool_names(tools)
          tool_definitions = tools.is_a?(Hash) ? tools.values : Array(tools)

          tool_definitions.filter_map do |tool|
            tool.respond_to?(:name) ? tool.name : tool.class.name
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
