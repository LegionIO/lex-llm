# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LexLLM::Provider::OpenAICompatible do
  let(:provider_class) do
    Class.new(LexLLM::Provider) do
      include LexLLM::Provider::OpenAICompatible

      def api_base = 'https://compatible.invalid'
    end
  end
  let(:provider) { provider_class.new(LexLLM.config) }
  let(:model) { LexLLM::Model::Info.new(id: 'model-a', provider: :openai_compatible) }

  it 'renders chat payloads for OpenAI-compatible servers' do
    payload = chat_payload

    expect(payload.values_at(:model, :stream, :temperature)).to eq(['model-a', false, 0.2])
    expect(payload[:messages]).to eq([{ role: 'user', content: 'hello' }])
  end

  it 'parses chat completion responses with usage and tool calls' do
    message = provider.send(:parse_completion_response, fake_response(completion_body))

    expect([message.content, message.input_tokens, message.output_tokens]).to eq(['hi', 3, 5])
    expect(message.tool_calls[:lookup].arguments).to eq('id' => 1)
  end

  it 'parses embedding responses for single and batch inputs' do
    single = provider.send(:parse_embedding_response, fake_response(embedding_body), model: 'embed', text: 'a')
    batch = provider.send(:parse_embedding_response, fake_response(embedding_body), model: 'embed', text: %w[a b])

    expect([single.vectors, batch.vectors]).to eq([[0.1], [[0.1], [0.2]]])
  end

  def chat_payload
    provider.send(:render_payload, [LexLLM::Message.new(role: :user, content: 'hello')], tools: {}, temperature: 0.2,
                                                                                         model: model, stream: false,
                                                                                         schema: nil, thinking: nil,
                                                                                         tool_prefs: nil)
  end

  def completion_body
    {
      'model' => 'model-a',
      'choices' => [{ 'message' => { 'content' => 'hi', 'tool_calls' => [tool_call] } }],
      'usage' => { 'prompt_tokens' => 3, 'completion_tokens' => 5 }
    }
  end

  def tool_call
    { 'id' => 'call-1', 'function' => { 'name' => 'lookup', 'arguments' => '{"id":1}' } }
  end

  def embedding_body
    { 'data' => [{ 'embedding' => [0.1] }, { 'embedding' => [0.2] }], 'usage' => { 'prompt_tokens' => 2 } }
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end
end
