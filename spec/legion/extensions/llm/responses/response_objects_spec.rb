# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'LLM normalized response objects' do
  let(:unsafe_metadata) do
    {
      reasoning_content: 'metadata secret',
      reasoning: 'metadata reasoning',
      thinking_text: 'metadata thinking',
      raw: { reasoning_content: 'nested raw secret' },
      'raw-response' => { reasoning_content: 'hyphen raw secret' },
      'provider-body' => { thinking_text: 'hyphen body secret' },
      vendor: 'vllm'
    }
  end
  let(:unsafe_raw) { { 'choices' => [{ 'message' => { 'content' => '<think>raw secret</think>visible' } }] } }

  it 'serializes chat responses without raw provider thinking fields' do
    response = Legion::Extensions::Llm::Responses::ChatResponse.new(
      content: "<think>tag secret</think>\nvisible",
      metadata: unsafe_metadata,
      raw: unsafe_raw
    )

    payload = response.to_h
    encoded = Legion::JSON.dump(payload)

    expect(payload).to eq(content: 'visible', metadata: { vendor: 'vllm' })
    expect(encoded).not_to include('reasoning', 'reasoning_content', 'thinking_text', '<think>', 'raw secret',
                                   'nested raw secret', 'hyphen raw secret', 'hyphen body secret')
    expect(response.to_internal_h).to include(
      thinking: 'metadata secretmetadata reasoningmetadata thinkingtag secret',
      metadata: unsafe_metadata,
      raw: unsafe_raw
    )
  end

  it 'serializes stream chunks without raw provider thinking fields' do
    chunk = Legion::Extensions::Llm::Responses::StreamChunk.new(
      content: "<think>tag secret</think>\nvisible",
      metadata: unsafe_metadata,
      raw: unsafe_raw
    )

    payload = chunk.to_h
    encoded = Legion::JSON.dump(payload)

    expect(payload).to eq(content: 'visible', metadata: { vendor: 'vllm' })
    expect(encoded).not_to include('reasoning', 'reasoning_content', 'thinking_text', '<think>', 'raw secret',
                                   'nested raw secret', 'hyphen raw secret', 'hyphen body secret')
    expect(chunk.to_internal_h).to include(
      thinking: 'metadata secretmetadata reasoningmetadata thinkingtag secret',
      metadata: unsafe_metadata,
      raw: unsafe_raw
    )
  end

  it 'serializes embedding responses without raw provider payloads' do
    response = Legion::Extensions::Llm::Responses::EmbeddingResponse.new(
      vectors: [[0.1]],
      model: 'embed',
      metadata: unsafe_metadata,
      raw: unsafe_raw
    )

    payload = response.to_h

    expect(payload).to eq(vectors: [[0.1]], model: 'embed', metadata: { vendor: 'vllm' })
    expect(Legion::JSON.dump(payload)).not_to include('raw secret')
    expect(response.to_internal_h).to include(metadata: unsafe_metadata, raw: unsafe_raw)
  end
end
# rubocop:enable RSpec/DescribeClass
