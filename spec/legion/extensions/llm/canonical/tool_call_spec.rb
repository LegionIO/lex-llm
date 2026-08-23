# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::ToolCall do
  let(:type_class) { described_class }
  let(:auto_generated_members) { [:id] }
  let(:type_source) do
    {
      id: 'call_1',
      name: 'get_weather',
      arguments: { location: 'San Francisco' },
      source: 'client',
      status: 'pending',
      category: 'weather',
      metadata: { origin: 'model' }
    }
  end

  it_behaves_like 'a canonical type'

  describe 'H1 — .new is as strict as the factories' do
    it 'rejects a poison source enum' do
      expect { described_class.new(name: 'x', source: :bogus) }
        .to raise_error(ArgumentError, /Invalid source: :bogus/)
    end

    it 'rejects JSON-string arguments (Hash only, O03a)' do
      expect { described_class.new(name: 'x', arguments: '{"a":1}') }
        .to raise_error(ArgumentError, /arguments expected Hash, got String/)
    end
  end

  describe 'T5 — enum law (declared enums enforced in both factories)' do
    it 'validates source against SOURCE_VALUES' do
      expect { described_class.build(name: 'x', source: 'client') }.not_to raise_error
      expect(described_class.build(name: 'x', source: 'client').source).to eq(:client)
      expect { described_class.build(name: 'x', source: :bogus) }
        .to raise_error(ArgumentError, /Invalid source: :bogus/)
      expect { described_class.from_hash(name: 'x', source: 'nope') }
        .to raise_error(ArgumentError, /Invalid source: :nope/)
    end

    it 'validates status against STATUS_VALUES' do
      expect(described_class.build(name: 'x', status: 'running').status).to eq(:running)
      expect { described_class.build(name: 'x', status: :finished) }
        .to raise_error(ArgumentError, /Invalid status: :finished/)
      expect { described_class.from_hash(name: 'x', status: 'done') }
        .to raise_error(ArgumentError, /Invalid status: :done/)
    end
  end

  describe 'O03a — arguments Hash only' do
    it 'does not parse JSON-string arguments (the parse + rescue are deleted)' do
      expect { described_class.build(name: 'x', arguments: '{"a":1}') }
        .to raise_error(ArgumentError, /arguments expected Hash, got String/)
      expect { described_class.from_hash(name: 'x', arguments: '{\"a\":1}') }
        .to raise_error(ArgumentError, /arguments expected Hash, got String/)
    end

    it 'defaults nil arguments to {} (documented no-arguments default)' do
      expect(described_class.build(name: 'x').arguments).to eq({})
      expect(described_class.from_hash(name: 'x').arguments).to eq({})
    end
  end

  describe 'with_result (canonical mutation-free update)' do
    it 'attaches the result and normalizes error' do
      tc = described_class.build(name: 'x', id: 'c1', status: 'running')
      done = tc.with_result(result: 'ok', status: :success, duration_ms: 12)
      expect(done.result).to eq('ok')
      expect(done.status).to eq(:success)
      expect(done.error).to be_nil
      expect(done.success?).to be(true)

      failed = tc.with_result(result: 'boom', status: :error)
      expect(failed.error).to eq('boom')
      expect(failed.error?).to be(true)
    end

    it 'validates the result status enum' do
      tc = described_class.build(name: 'x', id: 'c1', status: 'running')
      expect { tc.with_result(result: 'r', status: :bogus) }
        .to raise_error(ArgumentError, /Invalid status: :bogus/)
    end
  end
end
