# frozen_string_literal: true

# Shared examples for canonical provider translator conformance.
#
# Every provider translator must implement:
#   - render_request(canonical_request) => wire Hash
#   - parse_response(wire_hash) => Canonical::Response
#   - parse_chunk(raw_chunk) => Canonical::Chunk | nil
#   - capabilities => Hash
#
# Usage:
#   it_behaves_like 'a canonical provider translator', MyTranslatorClass

RSpec.shared_examples 'a canonical provider translator' do |translator_class|
  let(:translator) { translator_class.new }
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:conformance) { Canonical::Conformance }

  describe '#capabilities' do
    it 'returns a Hash' do
      expect(translator.capabilities).to be_a(Hash)
    end

    it 'includes a :provider key' do
      expect(translator.capabilities).to have_key(:provider)
      expect(translator.capabilities[:provider]).to be_a(String)
    end
  end

  describe '#render_request' do
    context 'with a simple text request' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_simple_text_request'))
      end

      it 'renders a non-empty wire payload' do
        wire = translator.render_request(canonical_req)
        expect(wire).to be_a(Hash)
        expect(wire).not_to be_empty
      end

      it 'includes model or messages' do
        wire = translator.render_request(canonical_req)
        expect(wire.keys & %i[model messages]).not_to be_empty
      end

      it 'preserves message content' do
        wire = translator.render_request(canonical_req)
        wire_str = wire.to_s
        expect(wire_str).to include('how are you')
      end
    end

    context 'with a system prompt' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_system_prompt_request'))
      end

      it 'renders the system prompt in provider-appropriate format' do
        wire = translator.render_request(canonical_req)
        wire_str = wire.to_s.downcase
        expect(wire_str).to match(/helpful|haiku/)
      end
    end

    context 'with parameter mapping' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_params_mapping_request'))
      end

      it 'renders params in provider-appropriate format' do
        wire = translator.render_request(canonical_req)
        expect(wire).to be_a(Hash)
        wire_str = wire.to_s
        expect(wire_str).to match(/[0-9]+/)
      end
    end

    context 'with tools defined' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_tools_request'))
      end

      it 'renders tools in provider format' do
        wire = translator.render_request(canonical_req)
        wire_str = wire.to_s.downcase
        expect(wire_str).to include('get_weather')
      end

      it 'includes tool parameters' do
        wire = translator.render_request(canonical_req)
        wire_str = wire.to_s.downcase
        expect(wire_str).to include('location')
      end
    end

    context 'with tool results continuation (multi-turn)' do
      let(:canonical_req) do
        canonical::Request.from_hash(
          conformance.fixture_symbolized('canonical_tool_results_continuation_request')
        )
      end

      it 'renders the full conversation history' do
        wire = translator.render_request(canonical_req)
        wire_str = wire.to_s.downcase
        expect(wire_str).to include('weather')
      end

      it 'renders mixed client and registry tool calls' do
        wire = translator.render_request(canonical_req)
        wire_str = wire.to_s.downcase
        expect(wire_str).to include('get_weather')
        expect(wire_str).to include('summarize')
      end
    end

    context 'with thinking enabled' do
      let(:canonical_req) do
        canonical::Request.from_hash(conformance.fixture_symbolized('canonical_thinking_request'))
      end

      it 'renders thinking configuration' do
        wire = translator.render_request(canonical_req)
        wire_str = wire.to_s.downcase
        expect(wire_str).to match(/think|reason|budget|effort/)
      end
    end

    context 'with streaming request' do
      let(:canonical_req) do
        canonical::Request.from_hash(
          conformance.fixture_symbolized('canonical_simple_text_request').merge({ 'stream' => true })
        )
      end

      it 'renders with streaming indicator' do
        wire = translator.render_request(canonical_req)
        wire_str = wire.to_s.downcase
        expect(wire_str).to include('stream')
      end
    end
  end

  # parse_response: tests translator.parse_response(wire_hash) => Canonical::Response
  # For self-test (echo translator), wire == canonical-form (symbolized).
  # Real provider translators convert provider-specific wire format to canonical.
  describe '#parse_response' do
    context 'with a simple text response' do
      let(:wire_response) { conformance.fixture_symbolized('canonical_simple_text_response') }

      it 'returns a Canonical::Response' do
        response = translator.parse_response(wire_response)
        expect(response).to be_a(canonical::Response)
      end

      it 'preserves text content' do
        response = translator.parse_response(wire_response)
        expect(response.text).to eq("I'm doing well, thank you for asking!")
      end

      it 'sets stop_reason' do
        response = translator.parse_response(wire_response)
        expect(response.stop_reason).to eq(:end_turn)
      end

      it 'includes usage data' do
        response = translator.parse_response(wire_response)
        expect(response.usage).to be_a(canonical::Usage)
        expect(response.usage.input_tokens).to eq(12)
        expect(response.usage.output_tokens).to eq(10)
      end
    end

    context 'with a tool use response' do
      let(:wire_response) { conformance.fixture_symbolized('canonical_tool_use_response') }

      it 'parses tool calls correctly' do
        response = translator.parse_response(wire_response)
        expect(response).to be_a(canonical::Response)
        expect(response.tool_call?).to be true
        expect(response.tool_calls).to be_an(Array)
        expect(response.tool_calls.first).to be_a(canonical::ToolCall)
        expect(response.stop_reason).to eq(:tool_use)
      end

      it 'preserves tool call arguments as a Hash' do
        response = translator.parse_response(wire_response)
        args = response.tool_calls.first.arguments
        expect(args).to be_a(Hash)
        expect(args[:location]).to eq('San Francisco, CA')
      end

      it 'has no text when response is tool-only' do
        response = translator.parse_response(wire_response)
        expect(response.text).to eq('')
      end
    end

    context 'with thinking response' do
      let(:wire_response) { conformance.fixture_symbolized('canonical_thinking_response') }

      it 'parses thinking content and signature' do
        response = translator.parse_response(wire_response)
        expect(response.thinking).to be_a(canonical::Thinking)
        expect(response.thinking.content).to include('quantum')
        expect(response.thinking.signature).to be_a(String)
      end

      it 'preserves thinking tokens in usage' do
        response = translator.parse_response(wire_response)
        expect(response.usage).to be_a(canonical::Usage)
        expect(response.usage.thinking_tokens).to eq(120)
      end
    end

    context 'with error response' do
      let(:wire_response) { conformance.fixture_symbolized('canonical_error_response') }

      it 'parses error responses without crashing' do
        response = translator.parse_response(wire_response)
        expect(response).to be_a(canonical::Response)
        expect(response.error?).to be true
        expect(response.stop_reason).to eq(:error)
      end

      it 'preserves error metadata' do
        response = translator.parse_response(wire_response)
        expect(response.metadata).to have_key(:error)
      end
    end

    context 'with empty response' do
      let(:wire_response) { conformance.fixture_symbolized('canonical_empty_response') }

      it 'handles empty responses gracefully' do
        response = translator.parse_response(wire_response)
        expect(response).to be_a(canonical::Response)
        expect(response.text).to eq('')
        expect(response.tool_calls).to eq([])
      end
    end
  end

  describe '#parse_chunk' do
    context 'with text delta chunks' do
      let(:stream_fixture) { conformance.fixture('canonical_streaming_text_chunks') }
      let(:chunks) { stream_fixture['chunks'] }

      it 'parses text delta chunks' do
        text_chunk = chunks.find { |c| c['type'] == 'text_delta' }
        parsed = translator.parse_chunk(text_chunk)
        expect(parsed).to be_a(canonical::Chunk)
        expect(parsed.type).to eq(:text_delta)
        expect(parsed.delta).to be_a(String)
      end

      it 'parses the done chunk' do
        done_chunk = chunks.find { |c| c['type'] == 'done' }
        parsed = translator.parse_chunk(done_chunk)
        expect(parsed).to be_a(canonical::Chunk)
        expect(parsed.type).to eq(:done)
        expect(parsed.stop_reason).to eq(:end_turn)
      end
    end

    context 'with thinking delta chunks' do
      let(:stream_fixture) { conformance.fixture('canonical_streaming_thinking_chunks') }
      let(:chunks) { stream_fixture['chunks'] }

      it 'parses thinking delta chunks' do
        thinking_chunk = chunks.find { |c| c['type'] == 'thinking_delta' }
        parsed = translator.parse_chunk(thinking_chunk)
        expect(parsed).to be_a(canonical::Chunk)
        expect(parsed.type).to eq(:thinking_delta)
      end

      it 'preserves signature on thinking deltas' do
        sig_chunk = chunks.find { |c| c['type'] == 'thinking_delta' && !c['signature'].nil? }
        next if sig_chunk.nil?

        parsed = translator.parse_chunk(sig_chunk)
        expect(parsed.signature).to be_a(String)
      end
    end

    context 'with tool call delta chunks' do
      let(:stream_fixture) { conformance.fixture('canonical_streaming_tool_call_chunks') }
      let(:chunks) { stream_fixture['chunks'] }

      it 'parses tool call delta chunks' do
        tool_chunk = chunks.find { |c| c['type'] == 'tool_call_delta' }
        parsed = translator.parse_chunk(tool_chunk)
        expect(parsed).to be_a(canonical::Chunk)
        expect(parsed.type).to eq(:tool_call_delta)
      end

      it 'preserves tool call identity across chunks' do
        tool_chunks = chunks.select { |c| c['type'] == 'tool_call_delta' }
        parsed_chunks = tool_chunks.map { |c| translator.parse_chunk(c) }
        ids = parsed_chunks.map { |c| c.tool_call&.id }
        expect(ids.uniq.length).to eq(1)
      end
    end

    context 'with error chunk' do
      let(:stream_fixture) { conformance.fixture('canonical_streaming_error_chunks') }
      let(:chunks) { stream_fixture['chunks'] }

      it 'parses error chunks' do
        error_chunk = chunks.find { |c| c['type'] == 'error' }
        parsed = translator.parse_chunk(error_chunk)
        expect(parsed).to be_a(canonical::Chunk)
        expect(parsed.type).to eq(:error)
        expect(parsed.error?).to be true
      end
    end
  end

  describe 'stop_reason mapping' do
    let(:matrix) { conformance.fixture_symbolized('canonical_stop_reason_matrix') }

    it 'maps all canonical stop reasons' do
      canonical::Response::STOP_REASONS.each do |reason|
        resp = canonical::Response.build(stop_reason: reason, text: 'test')
        expect(resp.stop_reason).to eq(reason)
      end
    end

    it 'rejects invalid stop reasons' do
      expect { canonical::Response.build(stop_reason: :invalid_reason, text: 'test') }
        .to raise_error(ArgumentError, /Invalid stop_reason/)
    end
  end

  describe 'round-trip consistency' do
    it 'accumulated chunks equal non-streaming response for text' do
      stream_fixture = conformance.fixture('canonical_streaming_text_chunks')
      chunks = stream_fixture['chunks']

      accumulated_text = ''
      final_stop_reason = nil

      chunks.each do |raw_chunk|
        chunk = translator.parse_chunk(raw_chunk)
        next unless chunk

        case chunk.type
        when :text_delta
          accumulated_text += chunk.delta
        when :done
          final_stop_reason = chunk.stop_reason
        end
      end

      expect(accumulated_text).to eq('Hello, world! How can I help you today?')
      expect(final_stop_reason).to eq(:end_turn)
    end

    it 'accumulated chunks equal non-streaming response for thinking + text' do
      stream_fixture = conformance.fixture('canonical_streaming_thinking_chunks')
      chunks = stream_fixture['chunks']

      accumulated_thinking = ''
      accumulated_text = ''
      final_stop_reason = nil
      final_signature = nil

      chunks.each do |raw_chunk|
        chunk = translator.parse_chunk(raw_chunk)
        next unless chunk

        case chunk.type
        when :thinking_delta
          accumulated_thinking += chunk.delta
          final_signature = chunk.signature if chunk.signature
        when :text_delta
          accumulated_text += chunk.delta
        when :done
          final_stop_reason = chunk.stop_reason
        end
      end

      expect(accumulated_thinking).not_to be_empty
      expect(accumulated_text).not_to be_empty
      expect(final_signature).to be_a(String)
      expect(final_stop_reason).to eq(:end_turn)
    end
  end
end
