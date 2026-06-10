# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::ToolCall do
  describe '.build' do
    it 'creates a tool call with required fields' do
      tc = described_class.build(name: 'search', arguments: { query: 'test' })

      expect(tc.name).to eq('search')
      expect(tc.arguments).to eq({ query: 'test' })
      expect(tc.id).to start_with('call_')
      expect(tc.arguments).to be_a(Hash)
    end

    it 'generates a random id' do
      tc1 = described_class.build(name: 'search')
      tc2 = described_class.build(name: 'search')

      expect(tc1.id).not_to eq(tc2.id)
    end

    it 'accepts all fields' do
      tc = described_class.build(
        id: 'call-1',
        exchange_id: 'ex-1',
        name: 'search',
        arguments: { query: 'test' },
        source: :registry,
        status: :pending,
        data_handling_classification: :public,
        policy_decision: :allowed
      )

      expect(tc.id).to eq('call-1')
      expect(tc.exchange_id).to eq('ex-1')
      expect(tc.source).to eq(:registry)
      expect(tc.status).to eq(:pending)
      expect(tc.data_handling_classification).to eq(:public)
      expect(tc.policy_decision).to eq(:allowed)
    end

    it 'defaults arguments to empty hash' do
      tc = described_class.build(name: 'search')

      expect(tc.arguments).to eq({})
    end
  end

  describe '.from_hash' do
    it 'parses from hash with symbol keys' do
      tc = described_class.from_hash(
        id: 'call-1',
        name: 'search',
        arguments: { query: 'test' },
        source: :registry
      )

      expect(tc.id).to eq('call-1')
      expect(tc.name).to eq('search')
      expect(tc.arguments).to eq({ query: 'test' })
      expect(tc.source).to eq(:registry)
    end

    it 'normalizes string source to symbol' do
      tc = described_class.from_hash(name: 'search', source: 'registry')

      expect(tc.source).to eq(:registry)
    end

    it 'normalizes string status to symbol' do
      tc = described_class.from_hash(name: 'search', status: 'success')

      expect(tc.status).to eq(:success)
    end

    it 'parses JSON string arguments to symbol keys per Legion::JSON convention' do
      tc = described_class.from_hash(
        name: 'search',
        arguments: '{"query":"test","limit":10}'
      )

      expect(tc.arguments).to eq({ query: 'test', limit: 10 })
    end

    it 'handles string keys' do
      tc = described_class.from_hash('name' => 'search', 'arguments' => '{}')

      expect(tc.name).to eq('search')
      expect(tc.arguments).to eq({})
    end

    it 'returns nil for nil source' do
      expect(described_class.from_hash(nil)).to be_nil
    end
  end

  describe '#with_result' do
    it 'returns a new tool call with result' do
      tc = described_class.build(name: 'search', source: :registry)
      result_tc = tc.with_result(result: { hits: 5 }, status: :success, duration_ms: 100)

      expect(result_tc.result).to eq({ hits: 5 })
      expect(result_tc.status).to eq(:success)
      expect(result_tc.duration_ms).to eq(100)
      expect(result_tc.finished_at).to be_a(Time)
    end

    it 'sets error on error status' do
      tc = described_class.build(name: 'search')
      result_tc = tc.with_result(result: 'not found', status: :error)

      expect(result_tc.error).to eq('not found')
      expect(result_tc.status).to eq(:error)
    end
  end

  describe 'predicates' do
    it 'identifies successful calls' do
      tc = described_class.build(name: 'search', status: :success)
      expect(tc.success?).to be true
      expect(tc.error?).to be false
    end

    it 'identifies error calls' do
      tc = described_class.build(name: 'search', status: :error)
      expect(tc.error?).to be true
      expect(tc.success?).to be false
    end
  end

  describe '#to_h' do
    it 'serializes to compact hash' do
      tc = described_class.build(name: 'search', arguments: { query: 'test' })
      hash = tc.to_h

      expect(hash).to include(id: tc.id, name: 'search', arguments: { query: 'test' })
    end
  end

  describe '#to_audit_hash' do
    it 'includes compliance fields' do
      tc = described_class.build(
        name: 'search',
        source: :registry,
        data_handling_classification: :public,
        policy_decision: :allowed
      )
      hash = tc.to_audit_hash

      expect(hash).to include(
        name: 'search',
        source: :registry,
        data_handling_classification: :public,
        policy_decision: :allowed
      )
    end
  end

  describe 'SOURCE_VALUES' do
    it 'includes all expected source types' do
      expect(described_class::SOURCE_VALUES).to eq(%i[client registry special extension mcp])
    end
  end

  describe 'STATUS_VALUES' do
    it 'includes all expected status types' do
      expect(described_class::STATUS_VALUES).to eq(%i[pending running success error])
    end
  end

  describe 'round-trip' do
    it 'preserves values through from_hash/to_h' do
      original = {
        id: 'call-1',
        name: 'search',
        arguments: { query: 'test' },
        source: 'registry',
        status: 'pending'
      }
      tc = described_class.from_hash(original)
      serialized = tc.to_h

      expect(serialized[:id]).to eq('call-1')
      expect(serialized[:name]).to eq('search')
      expect(serialized[:arguments]).to eq({ query: 'test' })
      expect(serialized[:source]).to eq(:registry)
      expect(serialized[:status]).to eq(:pending)
    end
  end
end
