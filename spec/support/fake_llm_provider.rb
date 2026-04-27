# frozen_string_literal: true

module SpecSupport
  class FakeLLMProvider < LexLLM::Provider
    class << self
      def configuration_options
        %i[fake_llm_api_key fake_llm_api_base]
      end

      def slug
        'fake_llm'
      end

      def configuration_requirements
        []
      end

      def capabilities
        Module.new do
          def self.chat?(_model) = true
          def self.streaming?(_model) = true
          def self.vision?(_model) = true
          def self.functions?(_model) = true
        end
      end
    end

    def api_base
      config.fake_llm_api_base || 'https://fake-llm.invalid/v1'
    end

    # rubocop:disable Metrics/ParameterLists, Metrics/PerceivedComplexity, Lint/UnusedMethodArgument
    def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil,
                 tool_prefs: nil)
      if block_given?
        yield LexLLM::Chunk.new(content: 'streamed ', role: :assistant)
        yield LexLLM::Chunk.new(content: 'response', role: :assistant)
      end

      if tools.any? && messages.none?(&:tool_result?)
        tool = tools.values.first
        return LexLLM::Message.new(
          role: :assistant,
          content: nil,
          model_id: model.id,
          tool_calls: {
            tool.name.to_sym => LexLLM::ToolCall.new(id: 'tool-call-1', name: tool.name, arguments: { value: 21 })
          },
          input_tokens: 12,
          output_tokens: 3
        )
      end

      content = if schema
                  Legion::JSON.generate({ answer: 42 })
                elsif thinking
                  'fake response with thinking enabled'
                elsif messages.any?(&:tool_result?)
                  "tool result: #{messages.last.content}"
                else
                  "fake response to #{messages.last.content}"
                end

      LexLLM::Message.new(
        role: :assistant,
        content: content,
        model_id: model.id,
        input_tokens: 10,
        output_tokens: 5
      )
    end
    # rubocop:enable Metrics/ParameterLists, Metrics/PerceivedComplexity, Lint/UnusedMethodArgument

    def embed(text, model:, dimensions:)
      size = dimensions || 3
      vectors = Array(text).map { Array.new(size, 0.5) }
      vectors = vectors.first unless text.is_a?(Array)

      LexLLM::Embedding.new(vectors: vectors, model: model, input_tokens: Array(text).size)
    end

    def moderate(_input, model:)
      LexLLM::Moderation.new(
        id: 'moderation-1',
        model: model,
        results: [{ 'flagged' => false, 'categories' => {}, 'category_scores' => {} }]
      )
    end

    def paint(_prompt, model:, size:, with: nil, mask: nil, params: {}) # rubocop:disable Metrics/ParameterLists, Lint/UnusedMethodArgument
      LexLLM::Image.new(data: Base64.strict_encode64('fake-image'), mime_type: 'image/png', model_id: model)
    end

    def transcribe(_audio_file, model:, language:, **)
      LexLLM::Transcription.new(text: 'fake transcript', model: model, language: language)
    end
  end

  class BackupFakeLLMProvider < FakeLLMProvider
    class << self
      def configuration_options
        %i[backup_fake_llm_api_key backup_fake_llm_api_base]
      end

      def slug
        'backup_fake_llm'
      end
    end
  end
end

RSpec.shared_context 'with fake llm provider' do
  before do
    LexLLM::Provider.register(:fake_llm, SpecSupport::FakeLLMProvider)
    LexLLM::Provider.register(:backup_fake_llm, SpecSupport::BackupFakeLLMProvider)
  end
end
