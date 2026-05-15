# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Assembles streaming responses from LLMs into complete messages.
      class StreamAccumulator
        include Legion::Logging::Helper

        attr_reader :content, :model_id, :tool_calls

        def initialize
          @content = +''
          @thinking_text = +''
          @thinking_signature = nil
          @tool_calls = {}
          @input_tokens = nil
          @output_tokens = nil
          @cached_tokens = nil
          @cache_creation_tokens = nil
          @thinking_tokens = nil
          @inside_think_tag = false
          @pending_think_tag = +''
          @active_think_close_tag = nil
          @untagged_preamble_pending = true
          @untagged_preamble_buffer = +''
          @latest_tool_call_id = nil
        end

        def add(chunk)
          log.debug { chunk.inspect } if Legion::Extensions::Llm.config.log_stream_debug
          @model_id ||= chunk.model_id

          @last_content_delta = +''
          @last_thinking_delta = +''
          handle_chunk_content(chunk)
          append_thinking_from_chunk(chunk)
          count_tokens chunk
          log.debug { inspect } if Legion::Extensions::Llm.config.log_stream_debug
        end

        def filtered_chunk(chunk) # rubocop:disable Metrics/PerceivedComplexity
          has_content = !@last_content_delta.empty?
          has_thinking = !@last_thinking_delta.empty?
          has_tokens = chunk.input_tokens&.positive? || chunk.output_tokens&.positive?
          return nil unless has_content || has_thinking || chunk.tool_call? || has_tokens

          Chunk.new(
            role: :assistant,
            content: has_content ? @last_content_delta : nil,
            thinking: has_thinking ? Thinking.build(text: @last_thinking_delta) : chunk.thinking,
            model_id: chunk.model_id,
            tool_calls: chunk.tool_calls,
            input_tokens: chunk.input_tokens,
            output_tokens: chunk.output_tokens,
            raw: chunk.raw
          )
        end

        def to_message(response)
          flush_pending_untagged_preamble

          Message.new(
            role: :assistant,
            content: content.empty? ? nil : content,
            thinking: Thinking.build(
              text: @thinking_text.empty? ? nil : @thinking_text,
              signature: @thinking_signature
            ),
            tokens: Tokens.build(
              input: @input_tokens,
              output: @output_tokens,
              cached: @cached_tokens,
              cache_creation: @cache_creation_tokens,
              thinking: @thinking_tokens
            ),
            model_id: model_id,
            tool_calls: tool_calls_from_stream,
            raw: response
          )
        end

        private

        def tool_calls_from_stream
          tool_calls.transform_values do |tc|
            arguments = parse_accumulated_arguments(tc.arguments)

            ToolCall.new(
              id: tc.id,
              name: tc.name,
              arguments: arguments,
              thought_signature: tc.thought_signature
            )
          end
        end

        def parse_accumulated_arguments(arguments)
          return arguments unless arguments.is_a?(String)
          return {} if arguments.empty?

          Legion::JSON.parse(arguments, symbolize_names: false)
        rescue Legion::JSON::ParseError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.stream.parse_tool_arguments')
          {}
        end

        def accumulate_tool_calls(new_tool_calls)
          log.debug { "Accumulating tool calls: #{new_tool_calls}" } if Legion::Extensions::Llm.config.log_stream_debug
          new_tool_calls.each_value do |tool_call|
            if tool_call.id
              start_tool_call(tool_call)
            else
              append_tool_call_fragment(tool_call)
            end
          end
        end

        def start_tool_call(tool_call)
          @tool_calls[tool_call.id] = ToolCall.new(
            id: tool_call.id.empty? ? SecureRandom.uuid : tool_call.id,
            name: tool_call.name,
            arguments: mutable_tool_arguments(tool_call.arguments),
            thought_signature: tool_call.thought_signature
          )
          @latest_tool_call_id = tool_call.id
        end

        def mutable_tool_arguments(arguments)
          if arguments.nil? || (arguments.respond_to?(:empty?) && arguments.empty?)
            +''
          elsif arguments.is_a?(String)
            +arguments
          else
            arguments
          end
        end

        def append_tool_call_fragment(tool_call)
          existing = @tool_calls[@latest_tool_call_id]
          return unless existing

          existing.arguments << tool_call.arguments.to_s
          return unless tool_call.thought_signature && existing.thought_signature.nil?

          existing.thought_signature = tool_call.thought_signature
        end

        def find_tool_call(tool_call_id)
          if tool_call_id.nil?
            @tool_calls[@latest_tool_call]
          else
            @latest_tool_call_id = tool_call_id
            @tool_calls[tool_call_id]
          end
        end

        def count_tokens(chunk)
          @input_tokens = chunk.input_tokens if chunk.input_tokens
          @output_tokens = chunk.output_tokens if chunk.output_tokens
          @cached_tokens = chunk.cached_tokens if chunk.cached_tokens
          @cache_creation_tokens = chunk.cache_creation_tokens if chunk.cache_creation_tokens
          @thinking_tokens = chunk.thinking_tokens if chunk.thinking_tokens
        end

        def handle_chunk_content(chunk)
          return accumulate_tool_calls(chunk.tool_calls) if chunk.tool_call?

          content_text = chunk.content || ''
          if content_text.is_a?(String)
            append_text_with_thinking(content_text)
          else
            @content << content_text.to_s
          end
        end

        def append_text_with_thinking(text)
          content_chunk, thinking_chunk = extract_think_tags(text)
          content_chunk, untagged_thinking = extract_untagged_preamble(content_chunk)
          @content << content_chunk
          @last_content_delta << content_chunk
          if untagged_thinking
            @thinking_text << untagged_thinking
            @last_thinking_delta << untagged_thinking
          end
          return unless thinking_chunk

          @thinking_text << thinking_chunk
          @last_thinking_delta << thinking_chunk
        end

        def extract_untagged_preamble(content_chunk)
          return [content_chunk, nil] unless @untagged_preamble_pending
          return [content_chunk, nil] unless @content.empty? && @thinking_text.empty?
          return [content_chunk, nil] if content_chunk.empty?

          candidate = @untagged_preamble_buffer + content_chunk
          return release_untagged_preamble(candidate) unless candidate_untagged_preamble?(candidate)

          content, thinking = Responses::ThinkingExtractor.extract_untagged_preamble(candidate)
          return release_untagged_preamble(content, thinking) if thinking
          return release_untagged_preamble(candidate) if complete_untagged_preamble_candidate?(candidate)

          @untagged_preamble_buffer = candidate
          ['', nil]
        end

        def candidate_untagged_preamble?(candidate)
          Responses::ThinkingExtractor.untagged_reasoning_preamble_candidate?(candidate)
        end

        def complete_untagged_preamble_candidate?(candidate)
          candidate.match?(/\n{2,}/) || candidate.length > Responses::ThinkingExtractor::UNTAGGED_PREAMBLE_MAX_LENGTH
        end

        def release_untagged_preamble(content, thinking = nil)
          @untagged_preamble_pending = false
          @untagged_preamble_buffer = +''
          [content, thinking]
        end

        def flush_pending_untagged_preamble
          return if @untagged_preamble_buffer.empty?

          content, thinking = Responses::ThinkingExtractor.extract_untagged_preamble(@untagged_preamble_buffer)
          if thinking
            @content << content
            @thinking_text << thinking
          else
            @content << @untagged_preamble_buffer
          end
          @untagged_preamble_buffer = +''
          @untagged_preamble_pending = false
        end

        def append_thinking_from_chunk(chunk)
          thinking = chunk.thinking
          return unless thinking

          if thinking.text
            @thinking_text << thinking.text.to_s
            @last_thinking_delta << thinking.text.to_s
          end
          @thinking_signature ||= thinking.signature # rubocop:disable Naming/MemoizedInstanceVariableName
        end

        def extract_think_tags(text)
          remaining = @pending_think_tag + text
          @pending_think_tag = +''

          output = +''
          thinking = +''

          until remaining.empty?
            remaining = if @inside_think_tag
                          consume_think_content(remaining, @active_think_close_tag, thinking)
                        else
                          consume_non_think_content(remaining, output)
                        end
          end

          [output, thinking.empty? ? nil : thinking]
        end

        def consume_think_content(remaining, end_tag, thinking)
          end_index = remaining.index(end_tag)
          if end_index
            thinking << remaining.slice(0, end_index)
            @inside_think_tag = false
            @active_think_close_tag = nil
            remaining.slice((end_index + end_tag.length)..) || +''
          else
            suffix_len = longest_suffix_prefix(remaining, [end_tag])
            thinking << remaining.slice(0, remaining.length - suffix_len)
            @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
            +''
          end
        end

        def consume_non_think_content(remaining, output)
          unmatched_close = next_stream_tag_match(remaining, :close)
          start_match = next_stream_tag_match(remaining, :open)
          if unmatched_close && (start_match.nil? || unmatched_close[:index] < start_match[:index])
            consume_unmatched_think_close(remaining, unmatched_close)
          elsif start_match
            output << remaining.slice(0, start_match[:index])
            @inside_think_tag = true
            @active_think_close_tag = start_match[:close_tag]
            remaining.slice((start_match[:index] + start_match[:tag].length)..) || +''
          else
            suffix_len = longest_suffix_prefix(remaining, stream_tag_tokens)
            output << remaining.slice(0, remaining.length - suffix_len)
            @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
            +''
          end
        end

        def consume_unmatched_think_close(remaining, close_match)
          thinking = remaining.slice(0, close_match[:index])
          @thinking_text << thinking
          @last_thinking_delta << thinking
          remaining.slice((close_match[:index] + close_match[:tag].length)..).to_s.sub(/\A[[:space:]]+/, '')
        end

        def next_stream_tag_match(text, type)
          matches = Responses::ThinkingExtractor::THINK_TAG_PAIRS.filter_map do |open_tag, close_tag|
            tag = type == :open ? open_tag : close_tag
            index = text.index(tag)
            { index: index, tag: tag, close_tag: close_tag } if index
          end
          matches.min_by { |match| match[:index] }
        end

        def stream_tag_tokens
          Responses::ThinkingExtractor::THINK_TAG_PAIRS.flat_map { |open_tag, close_tag| [open_tag, close_tag] }
        end

        def longest_suffix_prefix(text, tags)
          tags.map { |tag| longest_suffix_prefix_for_tag(text, tag) }.max || 0
        end

        def longest_suffix_prefix_for_tag(text, tag)
          max = [text.length, tag.length - 1].min
          max.downto(1) do |len|
            return len if text.end_with?(tag[0, len])
          end
          0
        end
      end
    end
  end
end
