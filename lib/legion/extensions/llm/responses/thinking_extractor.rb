# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Responses
        # Separates provider thinking markup from caller-visible text.
        module ThinkingExtractor
          Extraction = Struct.new(:content, :thinking, :signature, :metadata, keyword_init: true)

          THINK_TAG_PAIRS = [
            ['<thinking>', '</thinking>'],
            ['<think>',    '</think>']
          ].freeze
          # Gemma4 special tokens that leak into content text when the serving
          # engine fails to intercept them. <turn|> and <channel|> are stop
          # signals — content is truncated at the first occurrence.
          # Others are stripped entirely.
          LEAKED_STOP_TOKENS = ['<turn|>', '<|turn>', '<channel|>'].freeze
          LEAKED_STRIP_TOKENS = ['<|channel>', '<|turn|>'].freeze
          UNTAGGED_PREAMBLE_MAX_LENGTH = 4_000
          UNTAGGED_PREAMBLE_STARTS = [
            'the user',
            'the request',
            'the prompt',
            'the question',
            'i need',
            'i should',
            'i will',
            "i'll",
            'i can',
            'we need',
            'we should',
            'we will',
            "we'll",
            'we can',
            'let me'
          ].freeze
          UNTAGGED_PREAMBLE_PATTERNS = [
            /
              \AThe\s+(?:user|request|prompt|question)\b.*\b
              (?:let\s+me|i'll|i\s+will|i\s+should|i\s+need|i\s+can|respond|answer|reply)\b
            /imx,
            /
              \A(?:I|We)\s+(?:need|should|will|can)\s+(?:to\s+)?
              (?:answer|respond|reply|confirm|provide|explain|help)\b
            /imx,
            /\ALet me\s+(?:answer|respond|reply|confirm|provide|explain|help)\b/im
          ].freeze
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
            clean, untagged_thinking = extract_untagged_preamble(clean.strip)
            thinking_parts << untagged_thinking

            clean = truncate_at_leaked_stop_token(clean)
            clean = strip_leaked_tokens(clean)

            [clean, compact_thinking(thinking_parts)]
          end
          private_class_method :extract_from_content

          def truncate_at_leaked_stop_token(text)
            earliest = nil
            LEAKED_STOP_TOKENS.each do |token|
              idx = text.index(token)
              earliest = idx if idx && (earliest.nil? || idx < earliest)
            end
            earliest ? text[0, earliest].rstrip : text
          end
          private_class_method :truncate_at_leaked_stop_token

          def strip_leaked_tokens(text)
            LEAKED_STRIP_TOKENS.reduce(text) { |t, token| t.gsub(token, '') }
          end
          private_class_method :strip_leaked_tokens

          def extract_untagged_preamble(content)
            return [content, nil] unless content.is_a?(String)

            match = content.match(/\A(?<preamble>.+?)\n{2,}(?<visible>.+)\z/m)
            return [content, nil] unless match

            preamble = match[:preamble].strip
            return [content, nil] unless untagged_reasoning_preamble?(preamble)

            [match[:visible].sub(/\A[[:space:]]+/, '').strip, preamble]
          end

          def untagged_reasoning_preamble_candidate?(content)
            return false unless content.is_a?(String)

            text = content.lstrip.downcase
            return false if text.empty?

            UNTAGGED_PREAMBLE_STARTS.any? do |start|
              start.start_with?(text) || text.start_with?(start)
            end
          end

          def consume_next_segment(remaining, clean, thinking_parts)
            close_match = next_tag_match(remaining, :close)
            open_match = next_tag_match(remaining, :open)

            if close_match && (open_match.nil? || close_match[:index] < open_match[:index])
              thinking_parts << remaining.slice(0, close_match[:index])
              remaining.slice((close_match[:index] + close_match[:tag].length)..).to_s.sub(/\A[[:space:]]+/, '')
            elsif open_match
              consume_open_think_segment(remaining, open_match, clean, thinking_parts)
            else
              clean << remaining
              +''
            end
          end
          private_class_method :consume_next_segment

          def consume_open_think_segment(remaining, open_match, clean, thinking_parts)
            clean << remaining.slice(0, open_match[:index])
            after_open = remaining.slice((open_match[:index] + open_match[:tag].length)..).to_s
            close_index = after_open.index(open_match[:close_tag])
            unless close_index
              thinking_parts << after_open
              return +''
            end

            thinking_parts << after_open.slice(0, close_index)
            after_open.slice((close_index + open_match[:close_tag].length)..).to_s
          end
          private_class_method :consume_open_think_segment

          # The shared tag-segment matcher (10 U1): batch extraction and the
          # streaming state machine both match tags through this one
          # implementation.
          def next_tag_match(text, type)
            matches = THINK_TAG_PAIRS.filter_map do |open_tag, close_tag|
              tag = type == :open ? open_tag : close_tag
              index = text.index(tag)
              { index: index, tag: tag, close_tag: close_tag } if index
            end
            matches.min_by { |match| match[:index] }
          end

          # All tag tokens (opens + closes) for cross-chunk boundary buffering.
          def tag_tokens
            THINK_TAG_PAIRS.flat_map { |open_tag, close_tag| [open_tag, close_tag] }
          end

          def untagged_reasoning_preamble?(preamble)
            return false if preamble.length > UNTAGGED_PREAMBLE_MAX_LENGTH

            UNTAGGED_PREAMBLE_PATTERNS.any? { |pattern| preamble.match?(pattern) }
          end
          private_class_method :untagged_reasoning_preamble?

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
