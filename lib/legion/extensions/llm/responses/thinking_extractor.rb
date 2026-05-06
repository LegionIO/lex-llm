# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Responses
        # Separates provider thinking markup from caller-visible text.
        module ThinkingExtractor
          Extraction = Struct.new(:content, :thinking, :signature, :metadata, keyword_init: true)

          THINK_OPEN = '<think>'
          THINK_CLOSE = '</think>'
          THINK_PATTERN = %r{<think>(.*?)</think>}m
          THINKING_METADATA_KEYS = %i[
            reasoning_content reasoning thinking thinking_text thinking_signature reasoning_signature thought_signature
          ].freeze
          RAW_METADATA_KEYS = %i[
            raw raw_response response_body provider_body provider_response
          ].freeze

          module_function

          def extract(content, metadata: {})
            metadata = normalized_metadata(metadata)
            content, extracted_thinking = extract_from_content(content)
            metadata_thinking = extract_metadata_thinking(metadata)
            metadata_signature = extract_metadata_signature(metadata)

            Extraction.new(
              content: content,
              thinking: compact_thinking([metadata_thinking, extracted_thinking]),
              signature: metadata_signature,
              metadata: scrub_metadata(metadata)
            )
          end

          def extract_from_content(content)
            return [content, nil] unless content.is_a?(String)

            clean = +''
            thinking_parts = []
            remaining = content.dup

            remaining = consume_next_segment(remaining, clean, thinking_parts) until remaining.empty?

            [clean.strip, compact_thinking(thinking_parts)]
          end
          private_class_method :extract_from_content

          def consume_next_segment(remaining, clean, thinking_parts)
            close_index = remaining.index(THINK_CLOSE)
            open_index = remaining.index(THINK_OPEN)

            if close_index && (open_index.nil? || close_index < open_index)
              thinking_parts << remaining.slice(0, close_index)
              remaining.slice((close_index + THINK_CLOSE.length)..).to_s.sub(/\A[[:space:]]+/, '')
            elsif open_index
              consume_open_think_segment(remaining, open_index, clean, thinking_parts)
            else
              clean << remaining
              +''
            end
          end
          private_class_method :consume_next_segment

          def consume_open_think_segment(remaining, open_index, clean, thinking_parts)
            clean << remaining.slice(0, open_index)
            after_open = remaining.slice((open_index + THINK_OPEN.length)..).to_s
            close_index = after_open.index(THINK_CLOSE)
            unless close_index
              thinking_parts << after_open
              return +''
            end

            thinking_parts << after_open.slice(0, close_index)
            after_open.slice((close_index + THINK_CLOSE.length)..).to_s
          end
          private_class_method :consume_open_think_segment

          def extract_metadata_thinking(metadata)
            compact_thinking(
              [
                metadata[:reasoning_content],
                metadata[:reasoning],
                metadata[:thinking],
                metadata[:thinking_text]
              ]
            )
          end
          private_class_method :extract_metadata_thinking

          def extract_metadata_signature(metadata)
            [
              metadata[:thinking_signature],
              metadata[:reasoning_signature],
              metadata[:thought_signature]
            ].compact.map { |signature| signature.to_s.strip }.find { |signature| !signature.empty? }
          end
          private_class_method :extract_metadata_signature

          def scrub_metadata(metadata)
            metadata.each_with_object({}) do |(key, value), scrubbed|
              normalized_key = normalize_metadata_key(key)
              next if THINKING_METADATA_KEYS.include?(normalized_key) || RAW_METADATA_KEYS.include?(normalized_key)

              scrubbed[normalized_key] = scrub_metadata_value(value)
            end
          end
          private_class_method :scrub_metadata

          def normalize_metadata_key(key)
            key.to_s
               .gsub(/([a-z\d])([A-Z])/, '\1_\2')
               .tr('-', '_')
               .downcase
               .to_sym
          end
          private_class_method :normalize_metadata_key

          def scrub_metadata_value(value)
            case value
            when Hash
              scrub_metadata(normalized_metadata(value))
            when Array
              value.map { |item| scrub_metadata_value(item) }
            when String
              extract_from_content(value).first
            else
              value
            end
          end
          private_class_method :scrub_metadata_value

          def normalized_metadata(metadata)
            return {} if metadata.nil?

            metadata.to_h.transform_keys { |key| normalize_metadata_key(key) }
          end
          private_class_method :normalized_metadata

          def compact_thinking(parts)
            text = parts.compact.map { |part| part.to_s.strip }.reject(&:empty?).join
            blank_to_nil(text)
          end
          private_class_method :compact_thinking

          def blank_to_nil(value)
            value.nil? || value.empty? ? nil : value
          end
          private_class_method :blank_to_nil
        end
      end
    end
  end
end
