# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Responses
        # Normalized embedding provider response.
        class EmbeddingResponse
          attr_reader :vectors, :model, :tokens, :metadata, :raw

          def initialize(vectors:, model:, tokens: nil, metadata: {}, raw: nil)
            @vectors = vectors
            @model = model
            @tokens = tokens
            @metadata = ThinkingExtractor.extract(nil, metadata: metadata).metadata
            @internal_metadata = metadata.to_h
            @raw = raw

            freeze
          end

          def to_h
            {
              vectors: vectors,
              model: model,
              tokens: tokens,
              metadata: metadata
            }.compact
          end

          def to_internal_h
            to_h.merge(metadata: @internal_metadata, raw: raw).compact
          end
        end
      end
    end
  end
end
