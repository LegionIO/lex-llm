# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::StreamAccumulator do
  let(:canonical) { Legion::Extensions::Llm::Canonical }

  def text_chunk(delta)
    canonical::Chunk.text_delta(delta: delta, request_id: 'req-1')
  end

  def thinking_chunk(delta, signature: nil)
    canonical::Chunk.thinking_delta(delta: delta, request_id: 'req-1', signature:)
  end

  def tool_fragment(id: nil, name: nil, arguments: '', index: nil, signature: nil)
    canonical::Chunk.tool_call_delta(tool_call: { id:, name:, arguments:, index:, signature: }, request_id: 'req-1')
  end

  describe 'canonical chunk consumption (05 O5)' do
    it 'emits text deltas and accumulates the final text' do
      accumulator = described_class.new
      emitted = accumulator.add(text_chunk('hello '))
      emitted.concat(accumulator.add(text_chunk('world')))
      response = accumulator.to_response(model: 'm')

      expect(emitted.map { |c| [c.type, c.delta] }).to eq([[:text_delta, 'hello '], [:text_delta, 'world']])
      expect(response.text).to eq('hello world')
    end

    it 'emits provider thinking deltas and carries the signature into the response' do
      accumulator = described_class.new
      emitted = accumulator.add(thinking_chunk('hmm ', signature: 'sig-1'))
      response = accumulator.to_response(model: 'm')

      expect(emitted.map { |c| [c.type, c.delta] }).to eq([[:thinking_delta, 'hmm ']])
      expect(response.thinking.content).to eq('hmm ')
      expect(response.thinking.signature).to eq('sig-1')
    end

    it 'passes tool_call_delta chunks through and accumulates fragments' do
      accumulator = described_class.new
      emitted = accumulator.add(tool_fragment(id: 'call-1', name: 'f', arguments: '{"a"'))
      emitted.concat(accumulator.add(tool_fragment(arguments: ':1}')))

      expect(emitted.first).to be_a(canonical::Chunk)
      expect(emitted.first.type).to eq(:tool_call_delta)
      response = accumulator.to_response(model: 'm')
      expect(response.tool_calls.first.arguments).to eq('a' => 1)
    end

    it 'tracks usage from usage chunks into the response' do
      accumulator = described_class.new
      accumulator.add(canonical::Chunk.usage_chunk(
                        usage: canonical::Usage.build(input_tokens: 7, output_tokens: 3), request_id: 'req-1'
                      ))
      response = accumulator.to_response(model: 'm')

      expect(response.usage.input_tokens).to eq(7)
      expect(response.usage.output_tokens).to eq(3)
    end

    it 'keeps the last stop_reason and falls back to the selected model' do
      accumulator = described_class.new
      accumulator.add(canonical::Chunk.text_delta(delta: 'x', request_id: 'r', stop_reason: :end_turn))
      response = accumulator.to_response(model: 'selected-model')

      expect(response.stop_reason).to eq(:end_turn)
      expect(response.model).to eq('selected-model')
    end
  end

  describe 'tool-call fragment correlation (wire law: index first, recency fallback)' do
    it 'routes interleaved parallel fragments by wire index' do
      accumulator = described_class.new
      accumulator.add(tool_fragment(id: 'call-0', name: 'a', arguments: '{"x":', index: 0))
      accumulator.add(tool_fragment(id: 'call-1', name: 'b', arguments: '{"y":', index: 1))
      accumulator.add(tool_fragment(arguments: '1}', index: 0))
      accumulator.add(tool_fragment(arguments: '2}', index: 1))

      tool_calls = accumulator.to_response(model: 'm').tool_calls
      by_name = tool_calls.to_h { |tc| [tc.name, tc] }
      expect(by_name['a'].arguments).to eq('x' => 1)
      expect(by_name['b'].arguments).to eq('y' => 2)
    end

    it 'falls back to recency when the provider emits no index' do
      accumulator = described_class.new
      accumulator.add(tool_fragment(name: 'only', arguments: '{"a":'))
      accumulator.add(tool_fragment(arguments: '1}'))

      response = accumulator.to_response(model: 'm')
      expect(response.tool_calls.size).to eq(1)
      expect(response.tool_calls.first.arguments).to eq('a' => 1)
    end

    it 'opens a name-only call only while nothing is in flight; drops fragments with no call' do
      accumulator = described_class.new
      # A bare fragment before any opener is dropped (no call to route to).
      accumulator.add(tool_fragment(arguments: 'null'))
      accumulator.add(tool_fragment(name: 'first', arguments: '{"a":'))
      accumulator.add(tool_fragment(arguments: '1}'))

      tool_calls = accumulator.to_response(model: 'm').tool_calls
      expect(tool_calls.size).to eq(1)
      expect(tool_calls.first.name).to eq('first')
      expect(tool_calls.first.arguments).to eq('a' => 1)
    end

    it 'generates an id when the wire omits one' do
      accumulator = described_class.new
      accumulator.add(tool_fragment(name: 'anon', arguments: '{}'))
      response = accumulator.to_response(model: 'm')
      expect(response.tool_calls.first.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'carries the thought signature in the tool call metadata, never dropped' do
      accumulator = described_class.new
      accumulator.add(tool_fragment(id: 'c1', name: 'f', arguments: '{}', signature: 'thought-sig'))
      response = accumulator.to_response(model: 'm')
      expect(response.tool_calls.first.metadata).to eq(signature: 'thought-sig')
    end

    it 'raises a strict parse error for invalid assembled arguments (U2 — no rescue to {})' do
      accumulator = described_class.new
      accumulator.add(tool_fragment(id: 'c1', name: 'f', arguments: '{"broken"'))

      expect { accumulator.to_response(model: 'm') }
        .to raise_error(ArgumentError, /not valid JSON/)
    end
  end

  describe 'think-tag state machine (U1 — shared segment core, cross-chunk buffering)' do
    it 'splits think tags split across chunk boundaries without leaking' do
      accumulator = described_class.new
      emitted = []
      emitted.concat(accumulator.add(text_chunk('<thinking>')))
      emitted.concat(accumulator.add(text_chunk('internal</thin')))
      emitted.concat(accumulator.add(text_chunk('king>visible')))
      response = accumulator.to_response(model: 'm')

      expect(response.text).to eq('visible')
      expect(response.thinking.content).to eq('internal')
      # The split tag itself emits no visible text deltas.
      expect(emitted.map(&:type)).to eq(%i[thinking_delta text_delta])
    end

    it 'emits thinking and text deltas from a tagged stream' do
      accumulator = described_class.new
      emitted = []
      emitted.concat(accumulator.add(text_chunk('<thinking>')))
      emitted.concat(accumulator.add(text_chunk('reasoning here')))
      emitted.concat(accumulator.add(text_chunk('</thinking>and text')))

      expect(emitted.map(&:type)).to eq(%i[thinking_delta text_delta])
      response = accumulator.to_response(model: 'm')
      expect(response.text).to eq('and text')
      expect(response.thinking.content).to eq('reasoning here')
    end

    it 'treats content before an unmatched close as thinking (never visible)' do
      accumulator = described_class.new
      accumulator.add(text_chunk('preface</thinking>'))
      accumulator.add(text_chunk('visible'))
      response = accumulator.to_response(model: 'm')

      expect(response.text).to eq('visible')
      expect(response.thinking.content).to eq('preface')
    end

    it 'keeps a stray open tag siphoning content into thinking until close' do
      accumulator = described_class.new
      accumulator.add(text_chunk('preamble<thinking>'))
      accumulator.add(text_chunk('middle'))
      accumulator.add(text_chunk('</thinking>tail'))
      response = accumulator.to_response(model: 'm')

      expect(response.text).to eq('preambletail')
      expect(response.thinking.content).to eq('middle')
    end
  end

  describe 'untagged-preamble heuristic' do
    it 'withholds a reasoning-looking preamble until a blank line, then emits it as thinking' do
      accumulator = described_class.new
      emitted = []
      emitted.concat(accumulator.add(text_chunk("I need to answer this\n")))
      emitted.concat(accumulator.add(text_chunk("\n\nHere is the answer")))

      response = accumulator.to_response(model: 'm')
      expect(response.thinking.content).to eq('I need to answer this')
      expect(response.text).to eq('Here is the answer')
      expect(emitted.map(&:type).include?(:thinking_delta)).to be(true)
    end

    it 'releases held text as content when the preamble is not reasoning' do
      accumulator = described_class.new
      emitted = []
      emitted.concat(accumulator.add(text_chunk('Just a normal answer')))
      expect(emitted.map(&:type)).to eq(%i[text_delta])
      expect(accumulator.to_response(model: 'm').text).to eq('Just a normal answer')
    end

    it 'flushes still-held preamble text at stream end (short responses still stream)' do
      accumulator = described_class.new
      accumulator.add(text_chunk("Let me answer\nbriefly"))
      expect(accumulator.add(text_chunk('more')).map(&:type)).to eq([])
      emitted = accumulator.flush_pending_chunk

      expect(emitted.map(&:type)).to eq(%i[text_delta])
      expect(accumulator.to_response(model: 'm').text).to eq("Let me answer\nbrieflymore")
    end
  end

  describe 'response assembly' do
    it 'assembles a canonical response with usage, thinking, and tool calls' do
      accumulator = described_class.new
      accumulator.add(text_chunk('done'))
      accumulator.add(thinking_chunk('thought', signature: 'sig-9'))
      accumulator.add(tool_fragment(id: 'c1', name: 'f', arguments: '{"k":"v"}'))
      accumulator.add(canonical::Chunk.usage_chunk(
                        usage: canonical::Usage.build(input_tokens: 1, output_tokens: 2), request_id: 'r'
                      ))

      response = accumulator.to_response(model: 'm-1')
      expect(response).to be_a(canonical::Response)
      expect(response.text).to eq('done')
      expect(response.thinking.content).to eq('thought')
      expect(response.thinking.signature).to eq('sig-9')
      expect(response.tool_calls.first.arguments).to eq('k' => 'v')
      expect(response.usage.input_tokens).to eq(1)
    end

    it 'leaves thinking and usage nil when the stream carried none' do
      response = described_class.new.to_response(model: 'm')
      expect(response.thinking).to be_nil
      expect(response.usage).to be_nil
      expect(response.text).to eq('')
    end
  end
end
