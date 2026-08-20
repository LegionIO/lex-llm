# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Provider::OpenAICompatible do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
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
  let(:model_id) { 'model-a' }

  it 'renders chat payloads for OpenAI-compatible servers (canonical in, O4 temperature from Params)' do
    payload = chat_payload

    expect(payload.values_at(:model, :stream, :temperature)).to eq([model_id, false, 0.2])
    expect(payload[:messages]).to eq([{ role: 'user', content: 'hello' }])
  end

  it 'preserves assistant think tags in outbound OpenAI-compatible history' do
    message = canonical::Message.build(
      role: :assistant,
      content: "internal\n</thinking>\n\nHello"
    )

    payload = provider.send(
      :render_payload,
      [message],
      tools: {},
      model: model_id,
      stream: false,
      schema: nil,
      thinking: nil,
      tool_prefs: nil,
      params: canonical::Params.build(temperature: 0.2)
    )

    expect(payload[:messages]).to eq([{ role: 'assistant', content: "internal\n</thinking>\n\nHello" }])
  end

  it 'renders content block arrays in the OpenAI wire shape' do
    message = canonical::Message.build(
      role: :user,
      content: [canonical::ContentBlock.text('look at this'),
                canonical::ContentBlock.image(data: 'AAA=', media_type: 'image/png')]
    )

    payload = provider.send(
      :render_payload,
      [message],
      tools: {},
      model: model_id,
      stream: false,
      schema: nil,
      thinking: nil,
      tool_prefs: nil,
      params: nil
    )

    # Text blocks render as plain strings; non-text blocks as OpenAI content parts.
    expect(payload[:messages].first[:content]).to eq(
      ['look at this', { type: 'image', data: 'AAA=', media_type: 'image/png', source_type: :base64 }]
    )
  end

  it 'parses chat completion responses to a Canonical::Response with usage and tool calls (08 R2)' do
    response = provider.send(:parse_completion_response, fake_response(completion_body))

    expect(response).to be_a(canonical::Response)
    expect([response.text, response.usage.input_tokens, response.usage.output_tokens]).to eq(['hi', 3, 5])
    expect(response.tool_calls.first).to be_a(canonical::ToolCall)
    expect(response.tool_calls.first.arguments).to eq('id' => 1)
    expect(response.stop_reason).to be_nil
  end

  it 'maps finish_reason through the StopReasonMapping vocabulary' do
    response = provider.send(
      :parse_completion_response,
      fake_response({
                      'model' => 'model-a',
                      'choices' => [{ 'message' => { 'content' => 'hi' }, 'finish_reason' => 'tool_calls' }]
                    })
    )

    expect(response.stop_reason).to eq(:tool_use)
  end

  it 'strips malformed trailing think close tags from chat completion responses' do
    response = provider.send(
      :parse_completion_response,
      fake_response(completion_body(content: "hidden only\n</thinking>\n\nvisible"))
    )

    expect(response.text).to eq('visible')
    expect(response.thinking.content).to eq('hidden only')
  end

  it 'strips truncated think tags from chat completion responses' do
    response = provider.send(
      :parse_completion_response,
      fake_response(completion_body(content: "visible\n<thinking>hidden only"))
    )

    expect(response.text).to eq('visible')
    expect(response.thinking.content).to eq('hidden only')
  end

  it 'does not leak streamed think-tag content split across chunks' do
    accumulator = Legion::Extensions::Llm::StreamAccumulator.new
    emitted = []

    think_tag_stream.each do |content|
      emitted.concat(accumulator.add(provider.send(:build_chunk, stream_delta(content: content))))
    end

    message = accumulator.to_response(model: model_id)

    expect(emitted.select(&:text_delta?).map(&:delta)).to eq(['visible'])
    expect(emitted.select(&:thinking_delta?).map(&:delta).join).to eq('internal')
    expect(message.text).to eq('visible')
    expect(message.thinking.content).to eq('internal')
  end

  it 'builds canonical chunks from streamed data (O5 — canonical out)' do
    chunk = provider.send(:build_chunk, stream_delta(content: 'hello'))
    expect(chunk).to be_a(canonical::Chunk)
    expect(chunk.type).to eq(:text_delta)
    expect(chunk.delta).to eq('hello')

    usage_chunk = provider.send(:build_chunk, { 'choices' => [], 'usage' => { 'prompt_tokens' => 2 } })
    expect(usage_chunk.type).to eq(:usage)
    expect(usage_chunk.usage.input_tokens).to eq(2)
  end

  it 'emits tool_call_delta chunks carrying the wire fragment (U1/U2 shapes)' do
    chunk = provider.send(:build_chunk, stream_delta(tool_calls: [tool_call_delta_without_name]))
    expect(chunk).to be_a(canonical::Chunk)
    expect(chunk.type).to eq(:tool_call_delta)
    expect(chunk.tool_call).to eq(id: nil, name: nil, arguments: '{}', index: 0)
  end

  it 'accumulates streamed OpenAI-compatible tool call argument fragments' do
    accumulator = Legion::Extensions::Llm::StreamAccumulator.new

    tool_call_stream.each do |delta|
      accumulator.add(provider.send(:build_chunk, stream_delta(tool_calls: [delta])))
    end

    message = accumulator.to_response(model: model_id)
    expect(message.tool_calls.first.name).to eq('lookup')
    expect(message.tool_calls.first.arguments).to eq('city' => 'Chicago')
  end

  it 'renders embedding payloads with model ids' do
    payload = provider.send(:render_embedding_payload, 'hello', model: model_id, dimensions: 768)

    expect(payload).to eq(model: model_id, input: 'hello', dimensions: 768)
  end

  it 'parses embedding responses to the documented artifact Hash (05 §3)' do
    single = provider.send(:parse_embedding_response, fake_response(embedding_body), model: 'embed', text: 'a')
    batch = provider.send(:parse_embedding_response, fake_response(embedding_body), model: 'embed', text: %w[a b])

    expect(single[:embedding]).to eq([0.1])
    expect(batch[:embedding]).to eq([[0.1], [0.2]])
    expect(single[:usage]).to be_a(canonical::Usage)
  end

  it 'parses moderation responses to the documented artifact Hash (05 §3)' do
    body = { 'model' => 'mod-1', 'results' => [{ 'flagged' => true, 'categories' => { 'hate' => true } }] }
    result = provider.send(:parse_moderation_response, fake_response(body), model: 'mod-1')

    expect(result).to eq(model: 'mod-1', result: { flagged: true, categories: { 'hate' => true } })
  end

  it 'maps OpenAI-compatible model listings to explicit capabilities and modalities' do
    models = provider.send(:parse_list_models_response, fake_response(models_body), :compatible,
                           provider_class.capabilities)

    expect(models.map(&:capabilities)).to eq([%i[streaming function_calling tools], %i[embeddings embedding]])
    expect(models.map { |model| model.modalities.to_h }).to eq([
                                                                 { input: %w[text image], output: %w[text] },
                                                                 { input: %w[text], output: %w[embeddings] }
                                                               ])
  end

  def chat_payload
    message = canonical::Message.build(role: :user, content: 'hello')
    provider.send(
      :render_payload,
      [message],
      tools: {},
      model: model_id,
      stream: false,
      schema: nil,
      thinking: nil,
      tool_prefs: nil,
      params: canonical::Params.build(temperature: 0.2)
    )
  end

  def completion_body(content: 'hi')
    {
      'model' => model_id,
      'choices' => [{ 'message' => { 'content' => content, 'tool_calls' => [tool_call] } }],
      'usage' => { 'prompt_tokens' => 3, 'completion_tokens' => 5 }
    }
  end

  def tool_call
    { 'id' => 'call-1', 'function' => { 'name' => 'lookup', 'arguments' => '{"id":1}' } }
  end

  def tool_call_delta_without_name
    { 'index' => 0, 'function' => { 'arguments' => '{}' } }
  end

  def tool_call_stream
    [
      { 'index' => 0, 'id' => 'call-1', 'function' => { 'name' => 'lookup', 'arguments' => '{"city"' } },
      { 'index' => 0, 'function' => { 'arguments' => ':"Chicago"}' } }
    ]
  end

  def think_tag_stream
    ['<thinking>', 'internal', '</thinking>visible']
  end

  def stream_delta(content: nil, tool_calls: nil)
    { 'model' => model_id, 'choices' => [{ 'delta' => { 'content' => content, 'tool_calls' => tool_calls }.compact }] }
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
