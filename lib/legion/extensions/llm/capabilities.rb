# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Capability vocabulary normalization. Collapses aliases so provider-specific
      # capability names (:function_calling from Gemini, :tool_use from Anthropic, :tools
      # from OpenAI) compare as equal. Used on BOTH sides of request_lane capability
      # filtering (lane declaration and router request payload) — without this, vocabulary
      # differences silently mismatch and the router returns no lane.
      module Capabilities
        CANONICAL = %i[
          completion embedding streaming tools vision thinking structured_output
          moderation image audio_transcription audio_speech responses
        ].freeze

        ALIASES = {
          function_calling: :tools,
          tool_use: :tools,
          tool_calls: :tools,
          tool: :tools,
          functions: :tools,
          stream: :streaming,
          stream_chat: :streaming,
          responses_api: :responses,
          embeddings: :embedding,
          embed: :embedding,
          reasoning: :thinking,
          image_generation: :image,
          images: :image,
          audio_generation: :audio_speech,
          speech_generation: :audio_speech,
          transcription: :audio_transcription
        }.freeze

        module_function

        # Normalize a capability list — collapse aliases, downcase, dedup.
        def normalize(caps, **)
          Array(caps).compact.each_with_object([]) do |cap, normalized|
            next unless cap.respond_to?(:to_s)

            sym = cap.to_s.downcase.strip.tr('-', '_').to_sym
            next if sym.to_s.empty?

            normalized << canonical(sym)
          end.uniq.freeze
        end

        def merge(*sets, **)
          sets.flat_map { |set| normalize(set) }.uniq.freeze
        end

        def include_all?(available, required, **)
          required = normalize(required)
          return true if required.empty?

          normalized = normalize(available)
          required.all? { |cap| normalized.include?(cap) }
        end

        def canonical(capability)
          sym = capability.to_s.downcase.strip.tr('-', '_').to_sym
          ALIASES.fetch(sym, sym)
        end
      end
    end
  end
end
