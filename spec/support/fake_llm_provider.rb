# frozen_string_literal: true

module SpecSupport
  class FakeLLMProvider < Legion::Extensions::Llm::Provider
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
        yield Legion::Extensions::Llm::Chunk.new(content: 'streamed ', role: :assistant)
        yield Legion::Extensions::Llm::Chunk.new(content: 'response', role: :assistant)
      end

      if tools.any? && messages.none?(&:tool_result?)
        tool = tools.values.first
        return Legion::Extensions::Llm::Message.new(
          role: :assistant,
          content: nil,
          model_id: model.id,
          tool_calls: {
            tool.name.to_sym => Legion::Extensions::Llm::ToolCall.new(id: 'tool-call-1', name: tool.name,
                                                                      arguments: { value: 21 })
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

      Legion::Extensions::Llm::Message.new(
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

      Legion::Extensions::Llm::Embedding.new(vectors: vectors, model: model, input_tokens: Array(text).size)
    end

    def moderate(_input, model:)
      Legion::Extensions::Llm::Moderation.new(
        id: 'moderation-1',
        model: model,
        results: [{ 'flagged' => false, 'categories' => {}, 'category_scores' => {} }]
      )
    end

    def paint(_prompt, model:, size:, with: nil, mask: nil, params: {}) # rubocop:disable Metrics/ParameterLists, Lint/UnusedMethodArgument
      Legion::Extensions::Llm::Image.new(data: Base64.strict_encode64('fake-image'), mime_type: 'image/png',
                                         model_id: model)
    end

    def transcribe(_audio_file, model:, language:, **)
      Legion::Extensions::Llm::Transcription.new(text: 'fake transcript', model: model, language: language)
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

# Namespace module that mimics a real lex-llm-* provider extension.
# Models.scan_provider_classes discovers providers via this pattern.
module Legion
  module Extensions
    module Llm
      module FakeLlmProvider
        PROVIDER_FAMILY = :fake_llm

        def self.provider_class
          SpecSupport::FakeLLMProvider
        end
      end

      module BackupFakeLlmProvider
        PROVIDER_FAMILY = :backup_fake_llm

        def self.provider_class
          SpecSupport::BackupFakeLLMProvider
        end
      end
    end
  end
end

# Register provider-specific configuration options at load time,
# the same way real lex-llm-* extensions declare their options.
[SpecSupport::FakeLLMProvider, SpecSupport::BackupFakeLLMProvider].each do |klass|
  Array(klass.configuration_options).each do |key|
    Legion::Extensions::Llm::Configuration.send(:option, key, nil)
  end
end

RSpec.shared_context 'with fake llm provider' do
  # Provider modules are defined at load time above; no runtime registration needed.
end
