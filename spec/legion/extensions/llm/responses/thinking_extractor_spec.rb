# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Responses::ThinkingExtractor do
  it 'extracts normal think tags' do
    result = described_class.extract("<think>hidden</think>\n\nvisible")

    expect(result.content).to eq('visible')
    expect(result.thinking).to eq('hidden')
  end

  it 'extracts normal thinking tags' do
    result = described_class.extract("<thinking>hidden</thinking>\n\nvisible")

    expect(result.content).to eq('visible')
    expect(result.thinking).to eq('hidden')
  end

  it 'extracts malformed trailing close tag' do
    result = described_class.extract("hidden only\n</think>\n\nvisible")

    expect(result.content).to eq('visible')
    expect(result.thinking).to eq('hidden only')
  end

  it 'extracts malformed trailing thinking close tag' do
    result = described_class.extract("hidden only\n</thinking>\n\nvisible")

    expect(result.content).to eq('visible')
    expect(result.thinking).to eq('hidden only')
  end

  it 'extracts unterminated think blocks instead of leaking them as visible content' do
    result = described_class.extract("visible\n<think>hidden only")

    expect(result.content).to eq('visible')
    expect(result.thinking).to eq('hidden only')
  end

  it 'extracts untagged local-model reasoning preambles' do
    result = described_class.extract(
      "The user is just saying \"test\". Let me respond simply and confirm things are working.\n\n" \
      'Hey! Things are working on my end. What can I help you with?'
    )

    expect(result.content).to eq('Hey! Things are working on my end. What can I help you with?')
    expect(result.thinking)
      .to eq('The user is just saying "test". Let me respond simply and confirm things are working.')
  end

  it 'leaves normal text visible' do
    result = described_class.extract('visible only')

    expect(result.content).to eq('visible only')
    expect(result.thinking).to be_nil
  end

  it 'extracts provider-specific reasoning metadata without exposing reasoning fields as metadata' do
    result = described_class.extract(
      'visible',
      metadata: {
        'reasoning_content' => 'hidden',
        'thinking_signature' => 'sig-1',
        'reasoning-signature' => 'sig-2',
        'vendor' => 'vllm'
      }
    )

    expect(result.content).to eq('visible')
    expect(result.thinking).to eq('hidden')
    expect(result.signature).to eq('sig-1')
    expect(result.metadata).to eq(vendor: 'vllm')
  end
end
