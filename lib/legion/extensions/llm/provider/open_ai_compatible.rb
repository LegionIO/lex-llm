# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      class Provider
        # Shared OpenAI-compatible HTTP payload and response adapter.
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

          def render_payload(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:) # rubocop:disable Metrics/ParameterLists
            payload = {
              model: model.id,
              messages: format_openai_messages(messages),
              temperature: temperature,
              stream: stream,
              tools: format_openai_tools(tools),
              tool_choice: openai_tool_choice(tool_prefs),
              response_format: openai_response_format(schema),
              reasoning_effort: openai_reasoning_effort(thinking)
            }.compact
            payload[:stream_options] = { include_usage: true } if stream && stream_usage_supported?
            payload
          end

          def format_openai_messages(messages)
            messages.map do |message|
              {
                role: message.role.to_s,
                content: openai_content(message.content, role: message.role),
                tool_call_id: message.tool_call_id,
                tool_calls: format_openai_tool_calls(message.tool_calls)
              }.compact
            end
          end

          def openai_content(content, role:)
            return content.format if content.is_a?(Legion::Extensions::Llm::Content::Raw)
            return sanitize_openai_text(content, role:) unless content.respond_to?(:attachments)
            return sanitize_openai_text(content.text.to_s, role:) if content.attachments.empty?

            openai_content_parts(content)
          end

          def openai_content_parts(content)
            parts = []
            parts << { type: 'text', text: content.text.to_s } if content.text
            content.attachments.each do |attachment|
              parts << { type: 'image_url', image_url: { url: attachment.for_llm } } if attachment.image?
            end
            parts
          end

          def sanitize_openai_text(text, role:)
            return text unless role.to_sym == :assistant && text.is_a?(String)

            Responses::ThinkingExtractor.extract(text).content
          end

          def format_openai_tool_calls(tool_calls)
            return nil unless tool_calls&.any?

            tool_calls.values.map do |tool_call|
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
            return nil if tools.empty?

            tools.values.map do |tool|
              {
                type: 'function',
                function: {
                  name: tool.name,
                  description: tool.description,
                  parameters: tool.params_schema || { type: 'object', properties: {} }
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
            return nil unless thinking.is_a?(Hash)

            thinking[:effort] || thinking['effort']
          end

          def parse_completion_response(response)
            body = response.body
            choice = Array(body['choices']).first || {}
            message = choice['message'] || {}
            usage = body['usage'] || {}
            content, thinking = extract_thinking_from_completion(message)

            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: content,
              model_id: body['model'],
              tool_calls: parse_tool_calls(message['tool_calls']),
              thinking: thinking,
              input_tokens: usage['prompt_tokens'],
              output_tokens: usage['completion_tokens'],
              reasoning_tokens: usage.dig('completion_tokens_details', 'reasoning_tokens'),
              raw: body
            )
          end

          def extract_thinking_from_completion(message)
            extraction = Responses::ThinkingExtractor.extract(
              message['content'],
              metadata: thinking_metadata(message)
            )

            [
              extraction.content,
              Thinking.build(
                text: extraction.thinking,
                signature: extraction.signature
              )
            ]
          end

          def thinking_metadata(message)
            {
              reasoning_content: message['reasoning_content'],
              reasoning: message['reasoning'],
              thinking: message['thinking'],
              thinking_text: message['thinking_text'],
              thinking_signature: message['thinking_signature'],
              reasoning_signature: message['reasoning_signature']
            }.compact
          end

          def build_chunk(data)
            choice = Array(data['choices']).first || {}
            delta = choice['delta'] || {}
            usage = data['usage'] || {}
            content, thinking = extract_thinking_from_chunk(delta)

            Legion::Extensions::Llm::Chunk.new(
              role: :assistant,
              content: content,
              model_id: data['model'],
              tool_calls: parse_streaming_tool_calls(delta['tool_calls']),
              thinking: thinking,
              input_tokens: usage['prompt_tokens'],
              output_tokens: usage['completion_tokens'],
              raw: data
            )
          end

          def parse_streaming_tool_calls(tool_calls)
            return nil unless tool_calls&.any?

            tool_calls.to_h do |call|
              function = call.fetch('function', {})
              name = function['name']
              id = call['id']
              key = (name || id || call['index']).to_s.to_sym
              [
                key,
                Legion::Extensions::Llm::ToolCall.new(id: id, name: name, arguments: function['arguments'] || '')
              ]
            end
          end

          def extract_thinking_from_chunk(delta)
            reasoning = delta['reasoning_content'] || delta['reasoning']
            content = delta['content']

            if reasoning
              [content, Thinking.build(text: reasoning)]
            else
              [content, nil]
            end
          end

          def parse_tool_calls(tool_calls)
            return nil unless tool_calls&.any?

            tool_calls.to_h do |call|
              function = call.fetch('function', {})
              name = function['name']
              id = call['id'] || name || call['index']
              key = name || id
              [
                key.to_s.to_sym,
                Legion::Extensions::Llm::ToolCall.new(
                  id: id&.to_s,
                  name: name,
                  arguments: parse_tool_arguments(function['arguments'])
                )
              ]
            end
          end

          def parse_tool_arguments(arguments)
            return {} if arguments.nil? || arguments == ''
            return arguments if arguments.is_a?(Hash)

            Legion::JSON.parse(arguments, symbolize_names: false)
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.provider.parse_tool_arguments')
            {}
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

          def parse_embedding_response(response, model:, text:)
            vectors = response.body.fetch('data', []).map { |item| item['embedding'] }
            vectors = vectors.first unless text.is_a?(Array)
            usage = response.body['usage'] || {}

            Legion::Extensions::Llm::Embedding.new(vectors: vectors, model: model,
                                                   input_tokens: usage['prompt_tokens'].to_i)
          end

          def render_moderation_payload(input, model:)
            { model: model, input: input }.compact
          end

          def parse_moderation_response(response, model:)
            Legion::Extensions::Llm::Moderation.new(id: response.body['id'], model: response.body['model'] || model,
                                                    results: response.body.fetch('results', []))
          end

          def render_image_payload(prompt, model:, size:, with:, mask:, params:) # rubocop:disable Metrics/ParameterLists
            { model: model, prompt: prompt, size: size, image: with, mask: mask }.merge(params).compact
          end

          def parse_image_response(response, model:)
            image = response.body.fetch('data', []).first || {}
            Legion::Extensions::Llm::Image.new(
              url: image['url'],
              data: image['b64_json'],
              revised_prompt: image['revised_prompt'],
              model_id: model,
              usage: response.body['usage'] || {}
            )
          end

          def render_transcription_payload(file_part, model:, language:, **options)
            { model: model, file: file_part, language: language }.merge(options).compact
          end

          def parse_transcription_response(response, model:)
            Legion::Extensions::Llm::Transcription.new(
              text: response.body['text'],
              model: model,
              language: response.body['language'],
              duration: response.body['duration'],
              segments: response.body['segments']
            )
          end
        end
      end
    end
  end
end
