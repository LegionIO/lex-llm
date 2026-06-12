# frozen_string_literal: true

# Shared examples for canonical client translator conformance.
#
# Every client translator must implement:
#   - parse_request(body, env) → Canonical::Request
#   - format_response(canonical_response) → Hash
#   - format_chunk(canonical_chunk) → Hash | nil
#   - format_error(error, status) → [status, Hash]
#
# Usage:
#   it_behaves_like 'a canonical client translator', MyClientTranslatorClass
# rubocop:disable Lint/NonLocalExitFromIterator -- return guard is idiomatic in shared_example blocks
RSpec.shared_examples 'a canonical client translator' do |translator_class|
  let(:translator) { translator_class.new }
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:conformance) { Canonical::Conformance }

  describe '#parse_request' do
    context 'with a simple text request' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_simple_text_request'))
      end

      it 'returns a Canonical::Request' do
        return unless translator.respond_to?(:format_request)

        formatted = translator.format_request(canonical_req)
        return unless formatted

        parsed = translator.parse_request(formatted, {})
        expect(parsed).to be_a(canonical::Request)
        expect(parsed.messages).to be_an(Array)
        expect(parsed.messages.length).to be > 0
      end
    end

    context 'with a system prompt' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_system_prompt_request'))
      end

      it 'preserves the system prompt' do
        return unless translator.respond_to?(:format_request)

        formatted = translator.format_request(canonical_req)
        return unless formatted

        parsed = translator.parse_request(formatted, {})
        expect(parsed.system).to be_a(String)
        expect(parsed.system).to include('haiku')
      end
    end

    context 'with tools defined' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_tools_request'))
      end

      it 'preserves tool definitions' do
        return unless translator.respond_to?(:format_request)

        formatted = translator.format_request(canonical_req)
        return unless formatted

        parsed = translator.parse_request(formatted, {})
        expect(parsed.tools).to be_a(Hash)
        expect(parsed.tools.keys).to include(:get_weather)
      end
    end

    context 'with thinking enabled' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_thinking_request'))
      end

      it 'preserves thinking configuration' do
        return unless translator.respond_to?(:format_request)

        formatted = translator.format_request(canonical_req)
        return unless formatted

        parsed = translator.parse_request(formatted, {})
        expect(parsed.thinking).to be_a(canonical::Thinking::Config)
        expect(parsed.thinking.enabled?).to be true
      end
    end

    context 'with parameter mapping' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_params_mapping_request'))
      end

      it 'preserves sampling parameters' do
        return unless translator.respond_to?(:format_request)

        formatted = translator.format_request(canonical_req)
        return unless formatted

        parsed = translator.parse_request(formatted, {})
        expect(parsed.params).to be_a(canonical::Params)
        expect(parsed.params.max_tokens).to eq(2048)
        expect(parsed.params.temperature).to eq(0.7)
      end
    end
  end

  describe '#format_response' do
    context 'with a simple text response' do
      let(:canonical_resp) do
        canonical::Response.from_hash(conformance.fixture_symbolized('canonical_simple_text_response'))
      end

      it 'formats a valid client response' do
        formatted = translator.format_response(canonical_resp)
        expect(formatted).to be_a(Hash)
        expect(formatted).not_to be_empty
      end

      it 'includes the text content' do
        formatted = translator.format_response(canonical_resp)
        formatted_str = formatted.to_s
        expect(formatted_str).to include('doing well')
      end
    end

    context 'with a tool use response' do
      let(:canonical_resp) do
        canonical::Response.from_hash(conformance.fixture_symbolized('canonical_tool_use_response'))
      end

      it 'formats tool calls in client-appropriate format' do
        formatted = translator.format_response(canonical_resp)
        formatted_str = formatted.to_s.downcase
        expect(formatted_str).to include('get_weather')
      end

      it 'includes tool call arguments' do
        formatted = translator.format_response(canonical_resp)
        formatted_str = formatted.to_s
        expect(formatted_str).to include('San Francisco')
      end
    end

    context 'with a thinking response' do
      let(:canonical_resp) do
        canonical::Response.from_hash(conformance.fixture_symbolized('canonical_thinking_response'))
      end

      it 'includes thinking content in client format' do
        formatted = translator.format_response(canonical_resp)
        formatted_str = formatted.to_s.downcase
        expect(formatted_str).to match(/think|reason|quantum/)
      end
    end

    context 'with an error response' do
      let(:canonical_resp) do
        canonical::Response.from_hash(conformance.fixture_symbolized('canonical_error_response'))
      end

      it 'formats error responses without crashing' do
        formatted = translator.format_response(canonical_resp)
        expect(formatted).to be_a(Hash)
      end
    end
  end

  describe '#format_chunk' do
    context 'with text delta chunks' do
      let(:stream_fixture) { conformance.fixture('canonical_streaming_text_chunks') }
      let(:chunks_data) { stream_fixture['chunks'] }

      it 'formats text delta chunks' do
        text_chunk_hash = chunks_data.find { |c| c['type'] == 'text_delta' }
        chunk = canonical::Chunk.from_hash(text_chunk_hash)
        formatted = translator.format_chunk(chunk)

        return unless formatted

        expect(formatted).to be_a(Hash)
        formatted_str = formatted.to_s
        expect(formatted_str).to include(chunk.delta)
      end

      it 'formats the done chunk' do
        done_chunk_hash = chunks_data.find { |c| c['type'] == 'done' }
        chunk = canonical::Chunk.from_hash(done_chunk_hash)
        formatted = translator.format_chunk(chunk)

        return unless formatted

        expect(formatted).to be_a(Hash)
      end
    end

    context 'with thinking delta chunks' do
      let(:stream_fixture) { conformance.fixture('canonical_streaming_thinking_chunks') }
      let(:chunks_data) { stream_fixture['chunks'] }

      it 'formats thinking delta chunks' do
        thinking_chunk_hash = chunks_data.find { |c| c['type'] == 'thinking_delta' }
        chunk = canonical::Chunk.from_hash(thinking_chunk_hash)
        formatted = translator.format_chunk(chunk)

        return unless formatted

        expect(formatted).to be_a(Hash)
      end
    end

    context 'with tool call delta chunks' do
      let(:stream_fixture) { conformance.fixture('canonical_streaming_tool_call_chunks') }
      let(:chunks_data) { stream_fixture['chunks'] }

      it 'formats tool call delta chunks' do
        tool_chunk_hash = chunks_data.find { |c| c['type'] == 'tool_call_delta' }
        chunk = canonical::Chunk.from_hash(tool_chunk_hash)
        formatted = translator.format_chunk(chunk)

        return unless formatted

        expect(formatted).to be_a(Hash)
        formatted_str = formatted.to_s.downcase
        expect(formatted_str).to include('get_weather')
      end
    end
  end

  describe '#format_error' do
    it 'formats an error with status code' do
      error = StandardError.new('Test error')
      result = translator.format_error(error, 500)
      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
      expect(result[0]).to eq(500)
      expect(result[1]).to be_a(Hash)
    end
  end

  describe 'round-trip consistency' do
    context 'with request round-trip' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_simple_text_request'))
      end

      it 'preserves message content through format/parse cycle' do
        return unless translator.respond_to?(:format_request)

        formatted = translator.format_request(canonical_req)
        parsed = translator.parse_request(formatted, {})
        expect(parsed.messages.length).to eq(canonical_req.messages.length)
      end
    end

    context 'with response round-trip' do
      let(:canonical_resp) do
        canonical::Response.from_hash(conformance.fixture_symbolized('canonical_simple_text_response'))
      end

      it 'preserves text through format cycle' do
        formatted = translator.format_response(canonical_resp)
        formatted_str = formatted.to_s
        expect(formatted_str).to include(canonical_resp.text)
      end
    end
  end

  # G24 — execution-proxy response contract.
  #
  # When a server-executed LegionIO tool resolves before the canonical response
  # is returned, the tool_call carries `:result` and a server-tool source
  # (registry/special/extension/mcp). Client translators MUST surface that
  # exchange as a completed, NON-actionable item — the client must not try to
  # re-execute it. Per format:
  #
  #   * Claude /v1/messages — server_tool_use + server_tool_result content
  #     blocks (NOT plain tool_use). stop_reason end_turn once all server
  #     results are present.
  #   * Codex /v1/responses — completed function_call items (or message items)
  #     showing name+arguments+result, status 'completed' (NOT 'in_progress'
  #     or 'requires_action'). The response status is 'completed', not
  #     'requires_action'.
  #   * Codex /v1/chat/completions — finish_reason 'stop' (not 'tool_calls')
  #     when only server tools were called and they all have results; the
  #     server tool exchange does not appear as actionable tool_calls.
  #
  # Translators declare their family via `g24_format` (one of :claude_messages,
  # :openai_responses, :openai_chat) so the shared examples can pick the right
  # shape assertions. Translators that don't implement g24_format are skipped.
  describe 'G24 execution-proxy contract' do
    let(:canonical_resp) do
      canonical::Response.from_hash(conformance.fixture_symbolized('canonical_server_tool_use_response'))
    end

    let(:format) do
      next nil unless translator.respond_to?(:g24_format)

      translator.g24_format
    end

    context 'with a server-executed tool result in the canonical response' do
      it 'surfaces the server tool name in the formatted response' do
        next if format.nil?

        formatted = translator.format_response(canonical_resp)
        formatted_str = formatted.to_s
        expect(formatted_str).to include('legion_list_all_tools')
      end

      it 'surfaces the server tool result text in the formatted response' do
        next if format.nil?

        formatted = translator.format_response(canonical_resp)
        formatted_str = formatted.to_s
        expect(formatted_str).to include('legion_list_all_tools, legion_apollo_search')
      end

      it 'never surfaces server-executed tools as actionable items', :aggregate_failures do
        next if format.nil?

        formatted = translator.format_response(canonical_resp)

        case format
        when :claude_messages
          # Server-side tools must appear as server_tool_use, never tool_use.
          # The G24 contract says the model must know the call happened AND
          # the client must not re-execute, so server_tool_use+server_tool_result
          # are the only shape — plain tool_use would put the client in a
          # tool-loop trying to fulfill an already-resolved exchange.
          types = (formatted[:content] || formatted['content']).map { |b| b[:type] || b['type'] }
          expect(types).to include('server_tool_use')
          expect(types).to include('server_tool_result')
          expect(types).not_to include('tool_use')

          stop_reason = formatted[:stop_reason] || formatted['stop_reason']
          expect(stop_reason).to eq('end_turn')

          server_use = (formatted[:content] || formatted['content']).find do |b|
            (b[:type] || b['type']).to_s == 'server_tool_use'
          end
          expect(server_use[:name] || server_use['name']).to eq('legion_list_all_tools')

          server_result = (formatted[:content] || formatted['content']).find do |b|
            (b[:type] || b['type']).to_s == 'server_tool_result'
          end
          result_text = (server_result[:content] || server_result['content']).first
          expect(result_text[:text] || result_text['text']).to include('legion_list_all_tools')
        when :openai_responses
          status = formatted[:status] || formatted['status']
          expect(status).to eq('completed')

          output = formatted[:output] || formatted['output']
          actionable = output.select do |item|
            type = (item[:type] || item['type']).to_s
            status_str = (item[:status] || item['status']).to_s
            type == 'function_call' && status_str != 'completed'
          end
          expect(actionable).to be_empty,
                                "found actionable function_call items for server tools: #{actionable.inspect}"

          # action_required is the legacy requires-action surface — server
          # tools must never end up there.
          action_required = formatted[:action_required] || formatted['action_required']
          expect(action_required).to be_nil
        when :openai_chat
          choice = (formatted[:choices] || formatted['choices']).first
          finish_reason = choice[:finish_reason] || choice['finish_reason']
          expect(finish_reason).to eq('stop')

          message = choice[:message] || choice['message']
          actionable = (message[:tool_calls] || message['tool_calls'] || []).reject do |tc|
            (tc[:status] || tc['status']).to_s == 'completed'
          end
          expect(actionable).to be_empty,
                                "found actionable tool_calls for server tools: #{actionable.inspect}"
        else
          raise "unknown G24 format: #{format.inspect}"
        end
      end
    end

    it 'formats the streaming tool_call_delta with the registry source' do
      next if format.nil?

      # The streaming tool_call_delta carries the resolved server_tool result.
      # We don't assert the per-chunk SSE encoding here (that's the route's
      # event emitter contract); we assert format_chunk doesn't drop the call
      # and the source flows through.
      stream_fixture = conformance.fixture('canonical_streaming_server_tool_chunks')
      tool_chunk = stream_fixture['chunks'].find do |c|
        c['type'] == 'tool_call_delta' && c.dig('tool_call', 'result')
      end
      expect(tool_chunk).not_to be_nil

      chunk = canonical::Chunk.from_hash(tool_chunk)
      formatted = translator.format_chunk(chunk)

      next if formatted.nil?

      # Format-specific minimum: the tool name is reachable. Streaming
      # shape per format is asserted in the matrix harness; here we only
      # require that the server-tool name survives chunk formatting.
      expect(formatted.to_s).to include('legion_list_all_tools')
    end

    it 'parses a continuation request with a prior server-executed exchange losslessly' do
      next if format.nil?
      next unless translator.respond_to?(:format_request)

      # Each translator round-trips its own format. We render the canonical
      # continuation with format_request (when available) then re-parse —
      # the prior server tool exchange must survive intact.
      continuation_body = conformance.fixture_symbolized('canonical_server_tool_continuation_request')
      canonical_req = canonical::Request.from_hash(continuation_body)
      formatted_body = translator.format_request(canonical_req)
      next if formatted_body.nil?

      parsed = translator.parse_request(formatted_body, {})
      expect(parsed).to be_a(canonical::Request)

      # The assistant tool_call and the tool result both survive the cycle.
      roles = parsed.messages.map { |m| m.role.to_sym }
      expect(roles).to include(:assistant)
      expect(roles).to include(:tool)

      tool_msg = parsed.messages.find { |m| m.role.to_sym == :tool }
      expect(tool_msg.content.to_s).to include('legion_list_all_tools')
    end
  end
end
# rubocop:enable Lint/NonLocalExitFromIterator
