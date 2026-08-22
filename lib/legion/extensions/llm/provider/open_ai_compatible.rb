# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      class Provider
        # Shared OpenAI-compatible HTTP payload and response adapter — the
        # reference implementation for the OpenAI wire dialect (08 R3).
        # Renders FROM Canonical (render_payload) and parses TO Canonical
        # (parse_completion_response / build_chunk). Provider-dialect
        # translation (usage spellings, JSON-string arguments, reasoning
        # fields) lives here, at the edge (03 O03a).
        module OpenAICompatible
          def stream_usage_supported? = false
          def completion_url = '/v1/chat/completions'
          def stream_url = completion_url
          def models_url = '/v1/models'
          def moderation_url = '/v1/moderations'
          def embedding_url(**) = '/v1/embeddings'
          def transcription_url = '/v1/audio/transcriptions'

          def images_url(with:, mask:)
            with || mask ? '/v1/images/edits' : '/v1/images/generations'
          end

          private

          def render_payload(messages, tools:, model:, stream:, schema:, thinking:, params:, tool_prefs:) # rubocop:disable Metrics/ParameterLists
            payload = {
              model: model,
              messages: format_openai_messages(messages),
              temperature: maybe_normalize_temperature(params),
              stream: stream,
              tools: format_openai_tools(tools),
              tool_choice: openai_tool_choice(tool_prefs),
              response_format: openai_response_format(schema),
              reasoning_effort: openai_reasoning_effort(thinking)
            }.compact
            payload.merge!(openai_payload_params(params))
            payload[:stream_options] = { include_usage: true } if stream && stream_usage_supported?
            payload
          end

          # Canonical Params → OpenAI wire keys (edge translation, O03a).
          def openai_payload_params(params)
            return {} unless params

            {
              max_tokens: params.max_tokens,
              top_p: params.top_p,
              top_k: params.top_k,
              stop: params.stop_sequences,
              seed: params.seed,
              frequency_penalty: params.frequency_penalty,
              presence_penalty: params.presence_penalty,
              response_format: openai_response_format_value(params.response_format)
            }.compact
          end

          # response_format travels in its provider wire shape (client
          # translator concern): a wire Hash passes through, a mode String is
          # wrapped.
          def openai_response_format_value(response_format)
            return nil if response_format.nil?
            return response_format if response_format.is_a?(::Hash)

            { type: response_format.to_s }
          end

          def format_openai_messages(messages)
            messages.map do |message|
              {
                role: message.role.to_s,
                content: openai_content(message.content),
                tool_call_id: message.tool_call_id,
                tool_calls: format_openai_tool_calls(message.tool_calls)
              }.compact
            end
          end

          # L10: the role-parameterized sanitizer is deleted — text content
          # passes through verbatim in every role (the decision comment
          # below documents why).
          def openai_content(content)
            return content.map { |block| openai_content(block) } if content.is_a?(::Array)
            return content.to_s if content.nil? || content.is_a?(::String)

            return content.text.to_s if content.text?

            {
              type: content.type.to_s,
              text: content.text,
              data: content.data,
              media_type: content.media_type,
              source_type: content.source_type,
              name: content.name,
              id: content.id,
              input: content.input,
              tool_use_id: content.tool_use_id,
              is_error: content.is_error
            }.compact
          end

          # Thinking-tag pass-through decision (L10: the vestigial sanitizer
          # is deleted, the decision stays): qwen3.6 outputs thinking in
          # tags and expects to see its own reasoning on subsequent rounds.
          # The Anthropic API layer separates thinking into distinct content
          # blocks for client-facing responses; the OpenAI compat layer passes
          # them through untouched.

          def format_openai_tool_calls(tool_calls)
            return nil unless tool_calls&.any?

            # Array<Canonical::ToolCall> only (the legacy Hash shape is deleted).
            tool_calls.map do |tool_call|
              {
                id: tool_call.id,
                type: 'function',
                function: {
                  name: tool_call.name,
                  arguments: Legion::JSON.generate(tool_call.arguments || {})
                }
              }
            end
          end

          def format_openai_tools(tools)
            return nil if tools.nil? || tools.empty?

            tools.values.map do |tool|
              {
                type: 'function',
                function: {
                  name: Canonical::ToolSchema.tool_name(tool),
                  description: Canonical::ToolSchema.tool_description(tool),
                  parameters: Canonical::ToolSchema.extract(tool)
                }
              }
            end
          end

          def openai_tool_choice(tool_prefs)
            choice = tool_prefs && (tool_prefs[:choice] || tool_prefs['choice'])
            return nil unless choice
            return choice.to_s if %i[auto none required].include?(choice.to_sym)

            { type: 'function', function: { name: choice.to_s } }
          end

          def openai_response_format(schema)
            return nil unless schema

            schema_hash = schema.respond_to?(:to_h) ? schema.to_h : schema
            { type: 'json_schema', json_schema: schema_hash }
          end

          def openai_reasoning_effort(thinking)
            return nil unless thinking.is_a?(Canonical::Thinking::Config)

            thinking.effort
          end

          # One response-parse boundary (08 R2): returns Canonical::Response.
          def parse_completion_response(response)
            body = response.body
            choice = Array(body['choices']).first || {}
            message = choice['message'] || {}
            extraction = Responses::ThinkingExtractor.extract(
              message['content'],
              metadata: thinking_metadata(message)
            )

            Canonical::Response.build(
              text: extraction.content,
              thinking: thinking_value(extraction),
              tool_calls: parse_tool_calls(message['tool_calls']),
              usage: openai_usage_to_canonical(body['usage']),
              stop_reason: stop_reason_lookup(body.dig('choices', 0, 'finish_reason')),
              model: body['model']
            )
          end

          # One thinking-metadata key list (10 U3): both the sync and chunk
          # paths extract through the shared ThinkingExtractor core.
          def thinking_metadata(wire_message)
            Responses::ThinkingExtractor::THINKING_METADATA_KEYS.each_with_object({}) do |key, hash|
              value = wire_message[key.to_s]
              hash[key] = value unless value.nil?
            end
          end

          def thinking_value(extraction)
            return nil if extraction.thinking.nil? && extraction.signature.nil?

            Canonical::Thinking.build(content: extraction.thinking, signature: extraction.signature)
          end

          # OpenAI wire usage → canonical keys (edge translation, O03a).
          def openai_usage_to_canonical(usage)
            return nil if usage.to_h.empty?

            Canonical::Usage.build(
              input_tokens: usage['prompt_tokens'],
              output_tokens: usage['completion_tokens'],
              cache_read_tokens: usage.dig('prompt_tokens_details', 'cached_tokens') || usage.dig('input_tokens_details', 'cached_tokens'),
              thinking_tokens: usage.dig('completion_tokens_details', 'reasoning_tokens') || usage.dig('output_tokens_details', 'reasoning_tokens')
            )
          end

          # One chunk-parse boundary (08 R2): returns a Canonical::Chunk or an
          # Array of them. In-band think tags are NOT split here — tags split
          # across chunks are the accumulator's stateful job (U1); per-chunk
          # metadata (e.g. reasoning_content) is separated here, statelessly.
          def build_chunk(data)
            choice = Array(data['choices']).first || {}
            delta = choice['delta'] || {}
            usage = data['usage'] || {}

            chunks = []
            metadata = thinking_metadata(delta)
            if metadata.any?
              extraction = Responses::ThinkingExtractor.extract(nil, metadata:)
              if extraction.thinking
                chunks << Canonical::Chunk.thinking_delta(
                  delta: extraction.thinking, request_id: nil, signature: extraction.signature
                )
              end
            end
            content = delta['content']
            chunks << Canonical::Chunk.text_delta(delta: content.to_s, request_id: nil) if content
            chunks.concat(parse_streaming_tool_calls(delta['tool_calls']))
            canonical_usage = openai_usage_to_canonical(usage)
            chunks << Canonical::Chunk.usage_chunk(usage: canonical_usage, request_id: nil) if canonical_usage

            if chunks.empty?
              nil
            else
              (chunks.size == 1 ? chunks.first : chunks)
            end
          end

          def parse_streaming_tool_calls(tool_calls)
            return [] unless tool_calls&.any?

            tool_calls.filter_map do |call|
              function = call.fetch('function', {})
              name = function['name']
              id = call['id']
              index = call['index']
              arguments_fragment = function['arguments'].to_s
              next nil if id.nil? && name.nil? && index.nil? && arguments_fragment.empty?

              Canonical::Chunk.tool_call_delta(
                tool_call: { id: id, name: name, arguments: arguments_fragment, index: index },
                request_id: nil
              )
            end
          end

          # Sync tool calls: the ONE strict arguments parser (10 U2).
          def parse_tool_calls(tool_calls)
            return [] unless tool_calls&.any?

            tool_calls.map do |call|
              function = call.fetch('function', {})
              name = function['name']
              id = call['id'] || name || call['index']
              Canonical::ToolCall.build(
                name: name.to_s,
                id: id&.to_s,
                arguments: Responses::ToolArguments.parse!(function['arguments'])
              )
            end
          end

          def parse_list_models_response(response, provider, capabilities)
            response.body.fetch('data', []).map do |model|
              critical_capabilities = critical_capabilities_for(capabilities, model)
              Legion::Extensions::Llm::Model::Info.from_hash(
                id: model.fetch('id'),
                name: model['id'],
                provider: provider,
                created_at: model_created_at(model['created']),
                capabilities: critical_capabilities,
                modalities: modalities_for_capabilities(critical_capabilities),
                metadata: model
              )
            end
          end

          def model_created_at(value)
            value.is_a?(Numeric) ? Time.at(value).utc : value
          end

          def critical_capabilities_for(capabilities, model)
            return [] unless capabilities
            return capabilities.critical_capabilities_for(model) if capabilities.respond_to?(:critical_capabilities_for)

            {
              'streaming' => :streaming?,
              'function_calling' => :functions?,
              'vision' => :vision?,
              'embeddings' => :embeddings?,
              'moderation' => :moderation?,
              'image' => :images?,
              'audio_transcription' => :audio_transcription?
            }.filter_map do |capability, predicate|
              capability if capabilities.respond_to?(predicate) && capabilities.public_send(predicate, model)
            end
          end

          def modalities_for_capabilities(capabilities)
            if capabilities.include?('embeddings') && (capabilities - ['embeddings']).empty?
              { input: %w[text], output: %w[embeddings] }
            elsif capabilities.include?('image')
              { input: %w[text image], output: %w[image] }
            elsif capabilities.include?('audio_transcription')
              { input: %w[audio], output: %w[text] }
            else
              { input: %w[text image], output: %w[text] }
            end
          end

          def render_embedding_payload(text, model:, dimensions:)
            { model: model.respond_to?(:id) ? model.id : model, input: text, dimensions: dimensions }.compact
          end

          # 05 §3 documented artifact: { text:, model:, embedding: Array<Float>,
          # usage: Canonical::Usage }.
          def parse_embedding_response(response, model:, text:)
            vectors = response.body.fetch('data', []).map { |item| item['embedding'] }
            vectors = vectors.first unless text.is_a?(Array)
            usage = response.body['usage'] || {}

            {
              text: text,
              model: model.respond_to?(:id) ? model.id : model,
              embedding: vectors,
              usage: openai_usage_to_canonical(usage)
            }.compact
          end

          def render_moderation_payload(input, model:)
            input_text = input.is_a?(::Array) ? input.map(&:text).join("\n") : input
            { model: model, input: input_text }.compact
          end

          # 05 §3 documented artifact: { model:, result: { flagged:, categories: } }.
          def parse_moderation_response(response, model:)
            result = Array(response.body['results']).first || {}
            {
              model: response.body['model'] || model,
              result: {
                flagged: result['flagged'] == true,
                categories: result['categories'] || {}
              }
            }
          end

          def render_image_payload(prompt, model:, size:, with:, mask:, params:) # rubocop:disable Metrics/ParameterLists
            { model: model, prompt: prompt, size: size, image: with, mask: mask }.merge(params).compact
          end

          # 05 §3 documented artifact: { model:, image:, size: }.
          def parse_image_response(response, model:)
            image = response.body.fetch('data', []).first || {}
            {
              model: model,
              image: image['url'] || image['b64_json'],
              size: image['size']
            }.compact
          end

          def render_transcription_payload(file_part, model:, language:, **options)
            { model: model, file: file_part, language: language }.merge(options).compact
          end

          # 05 §3 documented artifact: { model:, text:, language:, duration: }.
          def parse_transcription_response(response, model:)
            {
              model: model,
              text: response.body['text'],
              language: response.body['language'],
              duration: response.body['duration']
            }.compact
          end
        end
      end
    end
  end
end
