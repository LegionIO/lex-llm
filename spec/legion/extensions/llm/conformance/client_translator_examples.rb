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
end
# rubocop:enable Lint/NonLocalExitFromIterator
