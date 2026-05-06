# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Responses
        # Normalized streaming provider response chunk.
        class StreamChunk
          attr_reader :content, :thinking, :metadata, :model, :tool_calls, :tokens, :raw, :internal_metadata

          def initialize(content: nil, thinking: nil, metadata: {}, model: nil, tool_calls: nil, tokens: nil, raw: nil) # rubocop:disable Metrics/ParameterLists
            extraction = ThinkingExtractor.extract(content, metadata: metadata)

            @content = extraction.content
            @thinking = thinking || extraction.thinking
            @metadata = extraction.metadata
            @internal_metadata = metadata.to_h
            @model = model
            @tool_calls = tool_calls
            @tokens = tokens
            @raw = raw

            freeze
          end

          def to_h
            {
              content: content,
              metadata: metadata,
              model: model,
              tool_calls: tool_calls,
              tokens: tokens
            }.compact
          end

          def to_internal_h
            to_h.merge(thinking: thinking, metadata: internal_metadata, raw: raw).compact
          end
        end
      end
    end
  end
end
