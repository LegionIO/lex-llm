# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::Request do
  describe '.build' do
    it 'creates a request with required fields' do
      req = described_class.build(messages: [{ role: :user, content: 'hello' }])

      expect(req.id).to start_with('req_')
      expect(req.messages).to be_an(Array)
      expect(req.messages.first).to be_a(Legion::Extensions::Llm::Canonical::Message)
      expect(req.stream).to be false
    end

    it 'accepts all fields' do
      req = described_class.build(
        id: 'req-1',
        messages: [{ role: :user, content: 'hello' }],
        system: 'You are helpful',
        tools: { search: Legion::Extensions::Llm::Canonical::ToolDefinition.build(name: 'search') },
        tool_choice: :auto,
        params: Legion::Extensions::Llm::Canonical::Params.from_hash(max_tokens: 4096),
        thinking: Legion::Extensions::Llm::Canonical::Thinking::Config.build(effort: 'high'),
        stream: true,
        conversation_id: 'conv-1',
        caller: 'test',
        routing: { provider: 'anthropic' },
        metadata: { source: 'cli' }
      )

      expect(req.id).to eq('req-1')
      expect(req.system).to eq('You are helpful')
      expect(req.tools).to be_a(Hash)
      expect(req.tool_choice).to eq(:auto)
      expect(req.params).to be_a(Legion::Extensions::Llm::Canonical::Params)
      expect(req.thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking::Config)
      expect(req.stream).to be true
      expect(req.conversation_id).to eq('conv-1')
      expect(req.caller).to eq('test')
      expect(req.routing).to eq({ provider: 'anthropic' })
      expect(req.metadata).to eq({ source: 'cli' })
    end

    it 'normalizes tool_choice string to symbol' do
      req = described_class.build(tool_choice: 'auto')

      expect(req.tool_choice).to eq(:auto)
    end

    it 'normalizes params from hash' do
      req = described_class.build(params: { max_tokens: 4096, temperature: 0.7 })

      expect(req.params).to be_a(Legion::Extensions::Llm::Canonical::Params)
      expect(req.params.max_tokens).to eq(4096)
    end

    it 'normalizes thinking config from hash' do
      req = described_class.build(thinking: { effort: 'high', budget: 10_000 })

      expect(req.thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking::Config)
      expect(req.thinking.effort).to eq('high')
    end

    it 'accepts tools as array' do
      req = described_class.build(
        tools: [{ name: 'search', description: 'Search' }]
      )

      expect(req.tools).to be_a(Hash)
      expect(req.tools.keys).to include('search')
    end

    it 'accepts tools as hash' do
      req = described_class.build(
        tools: { search: { name: 'search', description: 'Search' } }
      )

      expect(req.tools).to be_a(Hash)
      expect(req.tools[:search]).to be_a(Legion::Extensions::Llm::Canonical::ToolDefinition)
    end
  end

  describe '.from_hash' do
    it 'parses from hash with symbol keys' do
      req = described_class.from_hash(
        messages: [{ role: :user, content: 'hello' }],
        system: 'You are helpful',
        stream: true
      )

      expect(req.system).to eq('You are helpful')
      expect(req.stream).to be true
      expect(req.messages.first).to be_a(Legion::Extensions::Llm::Canonical::Message)
    end

    it 'moves unknown keys to metadata' do
      req = described_class.from_hash(
        messages: [{ role: :user, content: 'hello' }],
        custom_field: 'value',
        another_custom: 123
      )

      expect(req.metadata[:custom_field]).to eq('value')
      expect(req.metadata[:another_custom]).to eq(123)
    end

    it 'merges unknown keys with existing metadata' do
      req = described_class.from_hash(
        messages: [{ role: :user, content: 'hello' }],
        metadata: { existing: 'data' },
        custom_field: 'value'
      )

      expect(req.metadata[:existing]).to eq('data')
      expect(req.metadata[:custom_field]).to eq('value')
    end

    it 'returns nil for nil source' do
      expect(described_class.from_hash(nil)).to be_nil
    end
  end

  describe '#to_h' do
    it 'serializes to hash with nested objects' do
      req = described_class.build(
        messages: [{ role: :user, content: 'hello' }],
        system: 'You are helpful',
        params: Legion::Extensions::Llm::Canonical::Params.from_hash(max_tokens: 4096)
      )
      hash = req.to_h

      expect(hash[:id]).to start_with('req_')
      expect(hash[:system]).to eq('You are helpful')
      expect(hash[:params]).to eq({ max_tokens: 4096 })
    end

    it 'serializes messages as hashes' do
      req = described_class.build(
        messages: [{ role: :user, content: 'hello' }]
      )
      hash = req.to_h

      expect(hash[:messages]).to be_an(Array)
      expect(hash[:messages].first).to be_a(Hash)
    end

    it 'serializes tools as hashes' do
      req = described_class.build(
        tools: { search: Legion::Extensions::Llm::Canonical::ToolDefinition.build(name: 'search') }
      )
      hash = req.to_h

      expect(hash[:tools]).to be_a(Hash)
    end
  end

  describe 'round-trip' do
    it 'preserves values through from_hash/to_h' do
      original = {
        messages: [{ role: 'user', content: 'hello' }],
        system: 'You are helpful',
        stream: true,
        conversation_id: 'conv-1'
      }
      req = described_class.from_hash(original)
      serialized = req.to_h

      expect(serialized[:system]).to eq('You are helpful')
      expect(serialized[:stream]).to be true
      expect(serialized[:conversation_id]).to eq('conv-1')
    end
  end
end
