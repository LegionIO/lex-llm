# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Base class for LLM providers.
      class Provider
        include Streaming
        include Legion::Logging::Helper

        attr_reader :config, :connection

        def initialize(config)
          @config = config
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

        def list_models
          response = @connection.get models_url
          parse_list_models_response response, slug, capabilities
        end

        def embed(text, model:, dimensions:)
          payload = render_embedding_payload(text, model:, dimensions:)
          response = @connection.post(embedding_url(model:), payload)
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

          def register(name, provider_class)
            providers[name.to_sym] = provider_class
            Legion::Extensions::Llm::Configuration.register_provider_options(provider_class.configuration_options)
          end

          def resolve(name)
            return nil if name.nil?

            providers[name.to_sym]
          end

          def for(model)
            model_info = Models.find(model)
            resolve model_info.provider
          end

          def providers
            @providers ||= {}
          end

          def local_providers
            providers.select { |_slug, provider_class| provider_class.local? }
          end

          def remote_providers
            providers.select { |_slug, provider_class| provider_class.remote? }
          end

          def configured_providers(config)
            providers.select do |_slug, provider_class|
              provider_class.configured?(config)
            end.values
          end

          def configured_remote_providers(config)
            providers.select do |_slug, provider_class|
              provider_class.remote? && provider_class.configured?(config)
            end.values
          end
        end

        private

        def validate_paint_inputs!(with:, mask:)
          return if with.nil? && mask.nil?

          raise UnsupportedAttachmentError, "#{name} does not support image references in paint"
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
