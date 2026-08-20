# frozen_string_literal: true

module SpecSupport
  # Contract-conformant fake provider (0.8.0): canonical in, canonical out.
  # No HTTP — complete is overridden to return canned Canonical::Response
  # objects (and yield Canonical::Chunk for streams).
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

    def complete(messages, tools: [], model:, params: nil, headers: {}, schema: nil, thinking: nil, # rubocop:disable Metrics/ParameterLists, Lint/UnusedMethodArgument, Style/KeywordParametersOrder
                 tool_prefs: nil, &) # rubocop:disable Lint/UnusedMethodArgument
      enforce_canonical_messages!(messages)

      if block_given?
        yield Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'streamed ', request_id: nil)
        yield Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'response', request_id: nil)
        yield Legion::Extensions::Llm::Canonical::Chunk.done(request_id: nil, stop_reason: :end_turn)
      end

      has_tool_result = messages.any?(&:tool_call_id)
      if tools.any? && !has_tool_result
        tool = tools.values.first
        return Legion::Extensions::Llm::Canonical::Response.build(
          text: nil,
          tool_calls: [
            Legion::Extensions::Llm::Canonical::ToolCall.build(name: tool.name, id: 'tool-call-1',
                                                               arguments: { value: 21 })
          ],
          stop_reason: :tool_use,
          model: model,
          usage: Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 12, output_tokens: 3)
        )
      end

      content = if schema
                  Legion::JSON.generate({ answer: 42 })
                elsif thinking
                  'fake response with thinking enabled'
                elsif has_tool_result
                  "tool result: #{messages.last.text}"
                else
                  "fake response to #{messages.last.text}"
                end

      Legion::Extensions::Llm::Canonical::Response.build(
        text: content,
        model: model,
        stop_reason: :end_turn,
        usage: Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 10, output_tokens: 5)
      )
    end

    def embed(text:, model:, dimensions: nil, params: nil, headers: {})
      _ = [params, headers]
      size = dimensions || 3
      vectors = Array(text).map { Array.new(size, 0.5) }
      vectors = vectors.first unless text.is_a?(Array)

      {
        text: text,
        model: model,
        embedding: vectors,
        usage: Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: Array(text).size)
      }
    end

    def moderate(input:, model:)
      _ = input
      { model: model, result: { flagged: false, categories: {} } }
    end

    def image(prompt:, model:, size:, with: nil, mask: nil, params: {}) # rubocop:disable Metrics/ParameterLists
      _ = [prompt, with, mask, params]
      { model: model, image: Base64.strict_encode64('fake-image'), size: }
    end

    def transcribe(_audio_file, model:, language:, **)
      { model: model, text: 'fake transcript', language: }
    end

    # Records exactly-once disconnect for the callable-lifecycle contract; does
    # not add disconnect to ProviderContract::REQUIRED_SIGNATURES.
    def disconnect_count
      @disconnect_count || 0
    end

    def disconnect
      @disconnect_count = disconnect_count + 1
      super
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
