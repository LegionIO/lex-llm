# frozen_string_literal: true

require 'securerandom'

module Legion
  module Extensions
    module Llm
      # Assembles Canonical streaming chunks into a complete Canonical::Response.
      #
      # The provider's build_chunk yields Canonical::Chunk objects (text_delta /
      # thinking_delta / tool_call_delta / usage). This accumulator owns:
      #   - the stateful think-tag split (cross-chunk boundary buffering — the
      #     only streaming-specific code; the segment logic is shared with
      #     Responses::ThinkingExtractor, 10 U1),
      #   - the untagged-preamble heuristic,
      #   - tool-call fragment correlation: the provider's authoritative wire
      #     INDEX first, recency only as the fallback for providers that emit
      #     no index (the wire index-first/recency-fallback law).
      # Fragments are assembled into a complete JSON string before the ONE
      # strict arguments parser runs (10 U2).
      class StreamAccumulator
        include Legion::Logging::Helper

        attr_reader :model_id, :stop_reason

        def initialize(request_id: nil, conversation_id: nil, exchange_id: nil)
          @request_id = request_id
          @conversation_id = conversation_id
          @exchange_id = exchange_id
          @content = +''
          @thinking_text = +''
          @thinking_signature = nil
          @tool_calls = {}
          @stop_reason = nil
          @usage = {}
          @inside_think_tag = false
          @pending_think_tag = +''
          @active_think_close_tag = nil
          @untagged_preamble_pending = true
          @untagged_preamble_buffer = +''
          @latest_tool_call_id = nil
          @index_to_id = {}
        end

        # Consume one Canonical::Chunk; returns the Array of Canonical::Chunk
        # objects to emit to the caller (empty when nothing is emitted).
        def add(chunk)
          log.debug { chunk.inspect } if Legion::Extensions::Llm.config.log_stream_debug
          @model_id ||= chunk.metadata[:model] if chunk.metadata.is_a?(::Hash)
          @stop_reason = chunk.stop_reason if chunk.stop_reason
          track_usage(chunk.usage) if chunk.usage

          case chunk.type
          when :text_delta then add_text_delta(chunk)
          when :thinking_delta then add_thinking_delta(chunk)
          when :tool_call_delta then add_tool_call_delta(chunk)
          when :usage then [chunk]
          else []
          end
        end

        # Flush any text still held by the untagged-preamble heuristic so
        # short responses still stream at least one delta (the superset flush —
        # 10 #19: folds the buffer into content AND emits the held text).
        def flush_pending_chunk
          return [] if @untagged_preamble_buffer.empty?

          content, thinking = Responses::ThinkingExtractor.extract_untagged_preamble(@untagged_preamble_buffer)
          emitted = []
          if thinking
            @content << content
            @thinking_text << thinking
            emitted << thinking_delta_for(thinking)
            emitted << text_delta_for(content) unless content.empty?
          else
            @content << @untagged_preamble_buffer
            emitted << text_delta_for(@untagged_preamble_buffer)
          end
          @untagged_preamble_buffer = +''
          @untagged_preamble_pending = false
          emitted
        end

        # The accumulated Canonical::Response (05 O5). model falls back to the
        # Selection-derived model when the provider wire reported none.
        def to_response(model: nil)
          Canonical::Response.build(
            text: @content.empty? ? nil : @content,
            thinking: accumulated_thinking,
            tool_calls: accumulated_tool_calls,
            usage: accumulated_usage,
            stop_reason: @stop_reason,
            model: @model_id || model
          )
        end

        private

        def add_text_delta(chunk)
          emitted = []
          content_chunk, thinking_chunk = extract_think_tags(chunk.delta.to_s)
          content_chunk, untagged_thinking = extract_untagged_preamble(content_chunk)
          thinking_total = [untagged_thinking, thinking_chunk].compact.join
          thinking_total = nil if thinking_total.empty?
          if untagged_thinking
            log.debug '[llm][stream_accumulator] action=untagged_thinking_from_chunk ' \
                      "content_kept=#{content_chunk[0, 50].inspect} " \
                      "untagged_thinking=#{untagged_thinking[0, 100].inspect} " \
                      "inside_think_tag=#{@inside_think_tag}"
          end

          @content << content_chunk
          @thinking_text << thinking_total if thinking_total
          emitted << thinking_delta_for(thinking_total) if thinking_total
          emitted << text_delta_for(content_chunk) unless content_chunk.empty?
          emitted
        end

        def add_thinking_delta(chunk)
          thinking_text = chunk.delta.to_s
          @thinking_text << thinking_text
          @thinking_signature ||= chunk.signature
          thinking_text.empty? ? [] : [chunk]
        end

        def add_tool_call_delta(chunk)
          accumulate_tool_call_fragment(chunk.tool_call) if chunk.tool_call
          [chunk]
        end

        def thinking_delta_for(text)
          Canonical::Chunk.thinking_delta(
            delta: text, request_id: @request_id, conversation_id: @conversation_id, exchange_id: @exchange_id,
            signature: @thinking_signature
          )
        end

        def text_delta_for(text)
          Canonical::Chunk.text_delta(delta: text, request_id: @request_id, conversation_id: @conversation_id, exchange_id: @exchange_id)
        end

        def accumulated_thinking
          return nil if @thinking_text.empty?

          Canonical::Thinking.build(content: @thinking_text, signature: @thinking_signature)
        end

        def accumulated_tool_calls
          @tool_calls.values.map do |fragment|
            # The thought signature (provider dialect, e.g. Gemini) has no
            # canonical ToolCall member — it travels in metadata, never dropped.
            Canonical::ToolCall.build(
              name: fragment[:name].to_s,
              id: fragment[:id],
              arguments: Responses::ToolArguments.parse!(fragment[:arguments]),
              metadata: fragment[:signature] ? { signature: fragment[:signature] } : {}
            )
          end
        end

        def accumulated_usage
          return nil if @usage.empty?

          Canonical::Usage.build(**@usage)
        end

        def track_usage(usage)
          @usage[:input_tokens] = usage.input_tokens if usage.input_tokens
          @usage[:output_tokens] = usage.output_tokens if usage.output_tokens
          @usage[:cache_read_tokens] = usage.cache_read_tokens if usage.cache_read_tokens
          @usage[:cache_write_tokens] = usage.cache_write_tokens if usage.cache_write_tokens
          @usage[:thinking_tokens] = usage.thinking_tokens if usage.thinking_tokens
        end

        # Tool-call fragment correlation. The wire law (dead-stop postmortem,
        # documented edge trade-off — keep this comment in sync with the
        # behavior):
        #   - a continuation fragment (id=nil, name=nil) lands on the call at
        #     ITS provider index; recency (@latest_tool_call_id) is retained
        #     only as the fallback for providers that emit no index;
        #   - a continuation with an UNKNOWN index and no recency target is
        #     DROPPED (the incomplete JSON then fails the strict arguments
        #     parser at to_response — a dropped empty-string fragment is the
        #     known invisible case);
        #   - when the provider omits the tool-call id, a UUID is FABRICATED:
        #     the client sees an id the provider never issued, so downstream
        #     correlation must not assume provider-issued ids.
        def accumulate_tool_call_fragment(fragment)
          if fragment[:id]
            start_tool_call(fragment)
          elsif fragment[:name] && @latest_tool_call_id.nil?
            start_tool_call_without_id(fragment)
          else
            append_tool_call_fragment(fragment)
          end
        end

        def start_tool_call(fragment)
          raw_id = fragment[:id].to_s
          resolved_id = raw_id.empty? ? SecureRandom.uuid : raw_id
          @tool_calls[resolved_id] = {
            id: resolved_id,
            name: fragment[:name],
            arguments: +fragment[:arguments].to_s,
            signature: fragment[:signature]
          }
          @latest_tool_call_id = resolved_id
          @index_to_id[fragment[:index]] = resolved_id if fragment[:index]
        end

        def start_tool_call_without_id(fragment)
          generated_id = SecureRandom.uuid
          @tool_calls[generated_id] = {
            id: generated_id,
            name: fragment[:name],
            arguments: +fragment[:arguments].to_s,
            signature: fragment[:signature]
          }
          @latest_tool_call_id = generated_id
          @index_to_id[fragment[:index]] = generated_id if fragment[:index]
        end

        def append_tool_call_fragment(fragment)
          target_id = @index_to_id[fragment[:index]] if fragment[:index]
          target_id ||= @latest_tool_call_id
          existing = @tool_calls[target_id]
          return unless existing

          existing[:arguments] << fragment[:arguments].to_s
          existing[:signature] ||= fragment[:signature]
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

        # The stateful think-tag split — cross-chunk buffering only; the
        # tag-matching/segment logic is the shared ThinkingExtractor core (U1).
        def extract_think_tags(text)
          remaining = @pending_think_tag + text
          @pending_think_tag = +''

          output = +''
          thinking = +''

          if @inside_think_tag && text.length > 10
            log.debug '[llm][stream_accumulator] action=chunk_arrives_inside_think ' \
                      "text_length=#{text.length} text=#{text[0, 200].inspect} " \
                      "active_close_tag=#{@active_think_close_tag.inspect} " \
                      "content_so_far=#{@content.length} thinking_so_far=#{@thinking_text.length}"
          end

          until remaining.empty?
            remaining = if @inside_think_tag
                          consume_think_content(remaining, @active_think_close_tag, thinking)
                        else
                          consume_non_think_content(remaining, output, thinking)
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
            if @content.length.positive? && remaining.length > 20
              log.debug '[llm][stream_accumulator] action=think_consuming_without_close ' \
                        "end_tag=#{end_tag.inspect} consumed_chars=#{remaining.length} " \
                        "consumed_start=#{remaining[0, 80].inspect} " \
                        "total_thinking=#{thinking.length + remaining.length}"
            end
            suffix_len = longest_suffix_prefix(remaining, [end_tag])
            thinking << remaining.slice(0, remaining.length - suffix_len)
            @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
            +''
          end
        end

        def consume_non_think_content(remaining, output, thinking)
          unmatched_close = Responses::ThinkingExtractor.next_tag_match(remaining, :close)
          start_match = Responses::ThinkingExtractor.next_tag_match(remaining, :open)
          if unmatched_close && (start_match.nil? || unmatched_close[:index] < start_match[:index])
            rest, eaten = consume_unmatched_think_close(remaining, unmatched_close)
            thinking << eaten
            rest
          elsif start_match
            if @content.length > 10 || output.length > 10
              log.debug '[llm][stream_accumulator] action=think_tag_opened_mid_content ' \
                        "tag=#{start_match[:tag].inspect} " \
                        "content_before_tag=#{remaining.slice(0, start_match[:index])[0, 50].inspect} " \
                        "content_accumulated=#{@content.length} output_accumulated=#{output.length}"
            end
            output << remaining.slice(0, start_match[:index])
            @inside_think_tag = true
            @active_think_close_tag = start_match[:close_tag]
            remaining.slice((start_match[:index] + start_match[:tag].length)..) || +''
          else
            suffix_len = longest_suffix_prefix(remaining, Responses::ThinkingExtractor.tag_tokens)
            output << remaining.slice(0, remaining.length - suffix_len)
            @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
            +''
          end
        end

        def consume_unmatched_think_close(remaining, close_match)
          eaten = remaining.slice(0, close_match[:index])
          if eaten.length > 5
            log.debug '[llm][stream_accumulator] action=unmatched_close_eating_content ' \
                      "close_tag=#{close_match[:tag].inspect} " \
                      "eaten_chars=#{eaten.length} " \
                      "eaten_start=#{eaten[0, 80].inspect} " \
                      "inside_think_tag=#{@inside_think_tag} " \
                      "content_so_far=#{@content.length}"
          end
          [remaining.slice((close_match[:index] + close_match[:tag].length)..).to_s.sub(/\A[[:space:]]+/, ''), eaten]
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
