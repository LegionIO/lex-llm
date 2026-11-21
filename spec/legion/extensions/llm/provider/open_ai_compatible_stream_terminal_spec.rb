# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Provider::OpenAICompatible do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:provider_class) do
    Class.new(Legion::Extensions::Llm::Provider) do
      include Legion::Extensions::Llm::Provider::OpenAICompatible

      def api_base = 'https://compatible.example'
    end
  end
  let(:provider) { provider_class.new(Legion::Extensions::Llm.config) }
  let(:chunks) { [] }

  def run_http_stream(frames)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/v1/chat/completions') do |env|
        expect(Legion::JSON.load(env.body)).to include(model: 'selected-model', stream: true)
        env.status = 200
        env.response_headers = { 'content-type' => 'text/event-stream' }
        frames.each do |frame|
          wire = "data: #{Legion::JSON.dump(frame)}\n\n"
          # Exercise the real SSE parser across HTTP callback boundaries.
          midpoint = wire.bytesize / 2
          [wire.byteslice(0, midpoint), wire.byteslice(midpoint..)].each do |part|
            env.request.on_data.call(part, part.bytesize, env)
          end
          expect(chunks.count { |chunk| chunk.type == :done }).to eq(0)
        end
        env.request.on_data.call("data: [DONE]\n\n", 14, env)
        [200, env.response_headers, '']
      end
    end
    provider.connection.connection.builder.adapter :test, stubs
    response = provider.stream_chat([canonical::Message.build(role: :user, content: 'Continue.')], model: 'selected-model') do |chunk|
      chunks << chunk
    end
    stubs.verify_stubbed_calls
    response
  end

  def choice_frame(delta:, finish_reason: nil)
    { model: 'selected-model', choices: [{ index: 0, delta: delta, finish_reason: finish_reason }] }
  end

  { 'stop' => :end_turn, 'length' => :max_tokens, 'tool_calls' => :tool_use, 'content_filter' => :content_filter }.each do |wire_reason, reason|
    [false, true].each do |terminal_content|
      it "preserves #{wire_reason} with terminal content=#{terminal_content}, trailing usage, and exactly one final done" do
        frames = [choice_frame(delta: { content: 'Hello' })]
        if wire_reason == 'tool_calls'
          frames << choice_frame(delta: { tool_calls: [{ index: 0, id: 'call_lookup',
                                                         function: { name: 'lookup', arguments: '{}' } }] })
        end
        frames << choice_frame(delta: terminal_content ? { content: ' there.' } : {}, finish_reason: wire_reason)
        frames << { choices: [], usage: { prompt_tokens: 11, completion_tokens: 7,
                                          completion_tokens_details: { reasoning_tokens: 3 } } }

        response = run_http_stream(frames)

        expect(response.stop_reason).to eq(reason)
        expect(response.text).to eq(terminal_content ? 'Hello there.' : 'Hello')
        expect(response.usage).to have_attributes(input_tokens: 11, output_tokens: 7, thinking_tokens: 3)
        expect(response.tool_calls.map(&:name)).to eq(wire_reason == 'tool_calls' ? ['lookup'] : [])
        expect(chunks).to all(be_a(canonical::Chunk))
        expect(chunks.select { |chunk| chunk.type == :text_delta }.map(&:delta).join).to eq(response.text)
        expect(chunks.count { |chunk| chunk.type == :done }).to eq(1)
        expect(chunks.last).to have_attributes(type: :done, stop_reason: reason, usage: response.usage)
      end
    end
  end

  [nil, '', 'unrecognized_reason'].each do |wire_reason|
    it "does not fabricate successful completion for #{wire_reason.inspect}" do
      response = run_http_stream([
                                   choice_frame(delta: { content: 'Unconfirmed' }),
                                   choice_frame(delta: {}, finish_reason: wire_reason),
                                   { choices: [], usage: { prompt_tokens: 2, completion_tokens: 1 } }
                                 ])

      expect(response.stop_reason).to be_nil
      expect(response.text).to eq('Unconfirmed')
      expect(chunks.count { |chunk| chunk.type == :done }).to eq(1)
      expect(chunks.last).to have_attributes(type: :done, stop_reason: nil)
    end
  end
end
