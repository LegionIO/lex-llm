# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Represents a function call from an AI model to a Tool.
      class ToolCall
        attr_reader :id, :name, :arguments, :index
        attr_accessor :thought_signature

        # index carries the provider's authoritative wire position
        # (delta.tool_calls[N].index) so the StreamAccumulator can correlate
        # interleaved argument fragments to the right parallel call by index
        # rather than by recency. nil for non-streaming/single-call paths.
        def initialize(id:, name:, arguments: {}, thought_signature: nil, index: nil)
          @id = id
          @name = name
          @arguments = arguments
          @thought_signature = thought_signature
          @index = index
        end

        def to_h
          {
            id: @id,
            name: @name,
            arguments: @arguments,
            thought_signature: @thought_signature
          }.compact
        end
      end
    end
  end
end
