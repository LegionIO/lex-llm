# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Provider::OpenAICompatible do
  let(:provider_class) do
    capability_object = Object.new
    def capability_object.chat?(model) = !embeddings?(model)
    def capability_object.streaming?(model) = chat?(model)
    def capability_object.functions?(model) = chat?(model)
    def capability_object.embeddings?(model) = model.fetch('id').include?('embed')

    Class.new(Legion::Extensions::Llm::Provider) do
      include Legion::Extensions::Llm::Provider::OpenAICompatible

      define_singleton_method(:capabilities) { capability_object }
      def api_base = 'https://compatible.invalid'
    end
  end
  let(:provider) { provider_class.new(Legion::Extensions::Llm.config) }
  let(:model) { Legion::Extensions::Llm::Model::Info.new(id: 'model-a', provider: :openai_compatible) }

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

  it 'maps OpenAI-compatible model listings to explicit capabilities and modalities' do
    models = provider.send(:parse_list_models_response, fake_response(models_body), :compatible,
                           provider_class.capabilities)

    expect(models.map(&:capabilities)).to eq([%w[streaming function_calling], %w[embeddings]])
    expect(models.map { |model| model.modalities.to_h }).to eq([
                                                                 { input: %w[text image], output: %w[text] },
                                                                 { input: %w[text], output: %w[embeddings] }
                                                               ])
  end

  def chat_payload
    message = Legion::Extensions::Llm::Message.new(role: :user, content: 'hello')
    provider.send(
      :render_payload,
      [message],
      tools: {},
      temperature: 0.2,
      model: model,
      stream: false,
      schema: nil,
      thinking: nil,
      tool_prefs: nil
    )
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

  def models_body
    {
      'data' => [
        { 'id' => 'chat-model', 'created' => 1 },
        { 'id' => 'embed-model', 'created' => 2 }
      ]
    }
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end
end
