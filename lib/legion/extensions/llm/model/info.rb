# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Model
        CAPABILITY_ALIASES = {
          function_calling: :tools,
          functions: :tools,
          tool: :tools,
          tool_use: :tools,
          stream: :streaming,
          stream_chat: :streaming
        }.freeze

        Info = ::Data.define(
          :id, :name, :provider, :instance, :family,
          :capabilities, :context_length, :parameter_count,
          :parameter_size, :quantization, :size_bytes,
          :modalities_input, :modalities_output, :metadata
        ) do
          # rubocop:disable Metrics/ParameterLists, Metrics/PerceivedComplexity
          def initialize(
            id:, name: nil, provider: nil, instance: :default,
            family: nil, capabilities: [], context_length: nil,
            parameter_count: nil, parameter_size: nil, quantization: nil,
            size_bytes: nil, modalities_input: [], modalities_output: [],
            metadata: {}
          )
            normalized_family = family.nil? ? nil : family.to_s.downcase.strip

            super(
              id: id.to_s.strip,
              name: (name || id).to_s.strip,
              provider: provider.to_s.downcase.to_sym,
              instance: (instance || :default).to_s.downcase.to_sym,
              family: normalized_family,
              capabilities: normalize_symbols(capabilities),
              context_length: to_int(context_length),
              parameter_count: to_int(parameter_count),
              parameter_size: parameter_size&.to_s&.strip,
              quantization: quantization&.to_s&.strip,
              size_bytes: to_int(size_bytes),
              modalities_input: normalize_symbols(modalities_input),
              modalities_output: normalize_symbols(modalities_output),
              metadata: metadata.is_a?(Hash) ? metadata : {}
            )
          end
          # rubocop:enable Metrics/ParameterLists, Metrics/PerceivedComplexity

          # ── Capability predicates ─────────────────────────────────────

          def completion? = capabilities.include?(:completion)
          def embedding?  = capabilities.include?(:embedding)
          def vision?     = capabilities.include?(:vision)
          def tools?      = capabilities.include?(:tools)
          def thinking?   = capabilities.include?(:thinking)

          def supports?(capability)
            capabilities.include?(capability.to_s.downcase.to_sym)
          end

          # ── Backward-compatible accessors ─────────────────────────────
          # These bridge the legacy Model::Info class API used by Models,
          # OpenAICompatible, and provider gems. They read from metadata
          # where the old fields were stored.

          def context_window
            context_length || metadata[:context_window]
          end

          def max_output_tokens
            metadata[:max_output_tokens]
          end

          def max_tokens
            max_output_tokens
          end

          def created_at
            metadata[:created_at]
          end

          def knowledge_cutoff
            metadata[:knowledge_cutoff]
          end

          def modalities
            Modalities.new(input: modalities_input.map(&:to_s), output: modalities_output.map(&:to_s))
          end

          def pricing
            Pricing.new(metadata[:pricing] || {})
          end

          def display_name
            name
          end

          def label
            "#{provider} - #{display_name}"
          end

          def input_price_per_million
            pricing.text_tokens.input
          end

          def output_price_per_million
            pricing.text_tokens.output
          end

          def supports_vision?
            vision? || modalities_input.include?(:image)
          end

          def supports_video?
            modalities_input.include?(:video)
          end

          def supports_functions?
            tools? || capabilities.include?(:function_calling)
          end

          # Legacy capability predicates (string-based)
          %w[function_calling structured_output batch reasoning citations streaming].each do |cap|
            define_method "#{cap}?" do
              supports?(cap)
            end
          end

          def type
            output = modalities_output.map(&:to_s)
            return 'embedding' if output.include?('embeddings') || embedding?
            return 'moderation' if output.include?('moderation')
            return 'image' if output.include?('image')
            return 'audio' if output.include?('audio')
            return 'video' if output.include?('video')

            'chat'
          end

          # Factory for assumed-to-exist models without full metadata.
          def self.default(model_id, provider)
            new(
              id: model_id,
              name: model_id.tr('-', ' ').capitalize,
              provider: provider,
              capabilities: %w[function_calling streaming vision structured_output],
              modalities_input: %w[text image],
              modalities_output: %w[text],
              metadata: { warning: 'Assuming model exists, capabilities may not be accurate' }
            )
          end

          # Factory that accepts both legacy and new-style hashes and maps
          # them to the new struct fields. Handles round-tripping through to_h.
          def self.from_hash(data)
            data = data.transform_keys(&:to_sym) if data.is_a?(Hash)

            input_mods, output_mods = extract_modalities(data)

            new(
              id: data[:id],
              name: data[:name],
              provider: data[:provider],
              instance: data[:instance],
              family: data[:family],
              capabilities: data[:capabilities] || [],
              context_length: data[:context_length] || data[:context_window],
              parameter_count: data[:parameter_count],
              parameter_size: data[:parameter_size],
              quantization: data[:quantization],
              size_bytes: data[:size_bytes],
              modalities_input: input_mods,
              modalities_output: output_mods,
              metadata: build_metadata(data)
            )
          end

          private

          def normalize_symbols(value)
            Array(value).compact.each_with_object([]) do |item, normalized|
              symbol = item.to_s.downcase.strip.to_sym
              next if symbol.to_s.empty?

              normalized << symbol
              alias_symbol = CAPABILITY_ALIASES[symbol]
              normalized << alias_symbol if alias_symbol
            end.uniq
          end

          def to_int(value)
            return nil if value.nil?

            value.to_i
          end

          # Class-level helpers for from_hash normalization
          class << self
            private

            def extract_modalities(data) # rubocop:disable Metrics/PerceivedComplexity
              # New-style keys take priority (round-trip from to_h)
              if data.key?(:modalities_input) || data.key?(:modalities_output)
                return [Array(data[:modalities_input]), Array(data[:modalities_output])]
              end

              # Legacy: modalities is a hash or Modalities object
              modalities_data = data[:modalities]
              input_mods = if modalities_data.respond_to?(:input)
                             modalities_data.input
                           elsif modalities_data.is_a?(Hash)
                             Array(modalities_data[:input])
                           else
                             []
                           end
              output_mods = if modalities_data.respond_to?(:output)
                              modalities_data.output
                            elsif modalities_data.is_a?(Hash)
                              Array(modalities_data[:output])
                            else
                              []
                            end
              [input_mods, output_mods]
            end

            def build_metadata(data)
              extra = {}
              extra[:created_at] = normalize_created_at(data[:created_at]) if data.key?(:created_at)
              if data.key?(:knowledge_cutoff)
                extra[:knowledge_cutoff] =
                  normalize_knowledge_cutoff(data[:knowledge_cutoff])
              end
              extra[:max_output_tokens] = data[:max_output_tokens] if data.key?(:max_output_tokens)
              extra[:pricing] = normalize_pricing(data[:pricing]) if data.key?(:pricing)

              base = data[:metadata] || {}
              base.merge(extra).compact
            end

            def normalize_created_at(value)
              return nil if value.nil?
              return value if value.is_a?(Time)

              Utils.to_time(value)&.utc
            rescue StandardError
              nil
            end

            def normalize_knowledge_cutoff(value)
              return nil if value.nil?
              return value if value.is_a?(Date)

              Utils.to_date(value)
            rescue StandardError
              nil
            end

            def normalize_pricing(value)
              return nil if value.nil?
              return value.to_h if value.respond_to?(:to_h)

              value
            end
          end
        end
      end
    end
  end
end
