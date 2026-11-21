# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Provider::OpenAICompatible do
  def provider_for(output_key:)
    base = Class.new(Legion::Extensions::Llm::Provider) do
      include Legion::Extensions::Llm::Provider::OpenAICompatible

      def api_base = 'https://compatible.example'
    end
    provider_class = if output_key == :max_tokens
                       base
                     else
                       Class.new(base) { define_method(:output_token_limit_key) { output_key } }
                     end
    provider_class.new(Legion::Extensions::Llm.config)
  end

  def serve_response(env:, stream:)
    unless stream
      body = { model: 'selected-model', choices: [{ message: { content: 'OK' }, finish_reason: 'stop' }],
               usage: { prompt_tokens: 2, completion_tokens: 1 } }
      return [200, { 'content-type' => 'application/json' }, Legion::JSON.dump(body)]
    end

    env.status = 200
    env.response_headers = { 'content-type' => 'text/event-stream' }
    body = { model: 'selected-model', choices: [{ delta: { content: 'OK' }, finish_reason: 'stop' }],
             usage: { prompt_tokens: 2, completion_tokens: 1 } }
    wire = "data: #{Legion::JSON.dump(body)}\n\ndata: [DONE]\n\n"
    env.request.on_data.call(wire, wire.bytesize, env)
    [200, env.response_headers, '']
  end

  %i[max_tokens max_completion_tokens].each do |output_key|
    [false, true].each do |stream|
      [128, 64_000, nil, :absent_params].each do |limit|
        it "uses exactly the #{output_key} protocol field for #{limit.inspect}, stream=#{stream}, without changing canonical params" do
          provider = provider_for(output_key: output_key)
          params = (Legion::Extensions::Llm::Canonical::Params.build(max_tokens: limit, temperature: 0, top_p: 0.7) unless limit == :absent_params)
          original = params&.to_h
          expected = limit == :absent_params ? nil : limit
          payloads = []
          stubs = Faraday::Adapter::Test::Stubs.new do |stub|
            stub.post('/v1/chat/completions') do |env|
              payloads << Legion::JSON.load(env.body)
              serve_response(env: env, stream: stream)
            end
          end
          provider.connection.connection.builder.adapter :test, stubs
          messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Hello.')]
          chunks = []
          response = if stream
                       provider.stream_chat(messages, model: 'selected-model', params: params) { |chunk| chunks << chunk }
                     else
                       provider.chat(messages, model: 'selected-model', params: params)
                     end

          expect(payloads.size).to eq(1)
          payload = payloads.first
          expect(payload.keys & %i[max_tokens max_completion_tokens]).to eq(expected.nil? ? [] : [output_key])
          expect(payload[output_key]).to eq(expected)
          expect(payload).to include(temperature: 0, top_p: 0.7) if params
          expect(params&.to_h).to eq(original)
          expect(response).to have_attributes(text: 'OK', stop_reason: :end_turn)
          expect(chunks.count { |chunk| chunk.type == :done }).to eq(1) if stream
          stubs.verify_stubbed_calls
        end
      end
    end
  end
end
