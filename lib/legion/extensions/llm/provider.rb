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
          normalized_temperature = maybe_normalize_temperature(temperature, model)

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

        def discover_offerings(live: false, **filters)
          return filter_cached_offerings(Array(@cached_offerings), filters) unless live

          provider_health = health(live:)
          @cached_offerings = Array(list_models).filter_map do |model|
            next unless model_matches_filters?(model, filters)

            offering_from_model(model, health: provider_health)
          end
          @cached_offerings
        end

        def health(live: false)
          readiness_data = readiness(live:)
          raw_health = readiness_data[:health] || readiness_data['health'] || {}
          status = health_status(readiness_data, raw_health)
          {
            provider: slug.to_sym,
            instance_id: provider_instance_id,
            status:,
            ready: readiness_data[:ready] == true || readiness_data['ready'] == true,
            circuit_state: status == 'healthy' ? 'closed' : 'open',
            latency_ms: raw_health[:latency_ms] || raw_health['latency_ms'],
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
          _ = params
          payload = render_embedding_payload(text, model:, dimensions:)
          response = @connection.post(embedding_url(model:), payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
          end
          parse_embedding_response(response, model:, text:)
        end

        def moderate(input, model:)
          payload = render_moderation_payload(input, model:)
          response = @connection.post moderation_url, payload
          parse_moderation_response(response, model:)
        end

        def paint(prompt, model:, size:, with: nil, mask: nil, params: {}) # rubocop:disable Metrics/ParameterLists
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

        def model_whitelist
          wl = settings[:model_whitelist] if respond_to?(:settings)
          Array(wl).map { |p| p.to_s.downcase }
        end

        def model_blacklist
          bl = settings[:model_blacklist] if respond_to?(:settings)
          Array(bl).map { |p| p.to_s.downcase }
        end

        def model_allowed?(model_name)
          name = model_name.to_s.downcase
          wl = model_whitelist
          bl = model_blacklist

          return false if wl.any? && wl.none? { |p| name.include?(p) }
          return false if bl.any? && bl.any? { |p| name.include?(p) }

          true
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
        rescue StandardError
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
        rescue StandardError
          nil
        end

        def model_cache_set(key, value, ttl:)
          return unless defined?(Legion::Cache)

          cache_local_instance? ? local_cache_set(key, value, ttl: ttl) : cache_set(key, value, ttl: ttl)
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'lex.provider.model_cache_set')
        end

        def model_cache_fetch(key, ttl:, &)
          return yield unless defined?(Legion::Cache)

          cache_local_instance? ? local_cache_fetch(key, ttl: ttl, &) : cache_fetch(key, ttl: ttl, &)
        rescue StandardError
          yield
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

        def validate_paint_inputs!(with:, mask:)
          return if with.nil? && mask.nil?

          raise UnsupportedAttachmentError, "#{name} does not support image references in paint"
        end

        def offering_from_model(model, health: {})
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
            limits: offering_limits(model),
            health:,
            metadata: offering_metadata(model)
          )
        end

        def offering_transport
          local? ? :local : :http
        end

        def offering_tier
          local? ? :local : :direct
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

          status = raw_health[:status] || raw_health['status'] || raw_health[:state] || raw_health['state']
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
