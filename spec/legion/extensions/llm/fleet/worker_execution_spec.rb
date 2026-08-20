# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/worker_execution'
require 'support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Fleet::WorkerExecution do
  include SsotRegistryHelpers

  let(:key) { instance_key(family: 'vllm', instance: 'h200') }
  let(:callable) do
    Class.new do
      attr_reader :dispatched

      def initialize
        @dispatched = []
      end

      def chat(messages, model:, **rest)
        @dispatched << { operation: :chat, model: model, first: messages.first, rest: rest }
        Legion::Extensions::Llm::Canonical::Response.build(text: "#{model}:#{messages.first.text}", model: model)
      end
    end.new
  end
  let(:envelope) do
    {
      request_id: 'req-1',
      correlation_id: 'corr-1',
      idempotency_key: 'idem-1',
      operation: 'chat',
      provider: 'vllm',
      provider_instance: 'h200',
      model: 'gemma4',
      params: { messages: [{ role: 'user', content: 'hello' }] },
      reply_to: 'reply.1',
      message_context: {},
      caller: 'e2e',
      trace_context: {},
      signed_token: 'unsigned',
      timeout_seconds: 30,
      expires_at: (Time.now + 120).utc.iso8601,
      protocol_version: Legion::Extensions::Llm::Fleet::Protocol::VERSION,
      execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: Legion::Extensions::Llm::Inventory::Registry.snapshot
                                                               .offerings_for(instance_key: key).first.offering_id
    }
  end

  def activate!
    claim_and_activate(key: key, callable: callable, coordinator: probe_coordinator(key), model: 'gemma4')
  end

  before do
    Legion::Extensions::Llm::Inventory::Registry.reset!
    activate!
    described_class.reset_idempotency_cache!
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value).and_call_original
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :require_signed_token, default: true).and_return(false)
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :responder, :require_idempotency, default: nil).and_return(false)
  end

  it 'executes the exact request against the captured registry callable (W1/W2)' do
    response = described_class.call(envelope: envelope, registry: registry)

    expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(response.text).to eq('gemma4:hello')
    expect(callable.dispatched.first[:first]).to be_a(Legion::Extensions::Llm::Canonical::Message)
  end

  it 'requires registry — the provider-object topology is deleted (W1)' do
    expect { described_class.call(envelope: envelope, registry: nil) }
      .to raise_error(described_class::PolicyError, /requires registry/)
    expect(described_class.method(:call).parameters).to eq([%i[keyreq envelope], %i[keyreq registry]])
  end

  it 'rejects duplicate idempotency keys before executing the callable again (W7)' do
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :responder, :require_idempotency, default: nil).and_return(true)

    described_class.call(envelope: envelope, registry: registry)

    expect do
      described_class.call(envelope: envelope, registry: registry)
    end.to raise_error(described_class::PolicyError, /duplicate fleet idempotency key/)
  end

  it 'replaces expired idempotency entries while reserving the new attempt' do
    described_class.instance_variable_get(:@idempotency_keys)['idem-expired'] = {
      state: :complete,
      expires_at: Time.now.to_i - 1
    }

    expect { described_class.reserve_idempotency_key!('idem-expired') }.not_to raise_error

    expect do
      described_class.reserve_idempotency_key!('idem-expired')
    end.to raise_error(described_class::PolicyError, /duplicate fleet idempotency key/)
  end

  it 'reserves token replay before dispatch and marks success after (S4)' do
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :require_signed_token, default: true).and_return(true)
    allow(Legion::Extensions::Llm::Fleet::TokenValidator).to receive(:validate!).and_return({ jti: 'jti-1' })
    allow(Legion::Extensions::Llm::Fleet::TokenValidator).to receive(:mark_replay!)

    described_class.call(envelope: envelope, registry: registry)

    expect(Legion::Extensions::Llm::Fleet::TokenValidator).to have_received(:mark_replay!).with('jti-1')
  end

  it 'releases reserved replay state when dispatch fails (S4)' do
    failing_callable = Class.new { def chat(*, **) = raise('provider unavailable') }.new
    key2 = instance_key(family: 'vllm', instance: 'h201')
    claim_and_activate(key: key2, callable: failing_callable, coordinator: probe_coordinator(key2), model: 'gemma4')
    failing_envelope = envelope.merge(provider_instance: 'h201',
                                      offering_id: Legion::Extensions::Llm::Inventory::Registry.snapshot
                                                                                               .offerings_for(instance_key: key2).first.offering_id)
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :require_signed_token, default: true).and_return(true)
    allow(Legion::Extensions::Llm::Fleet::TokenValidator).to receive(:validate!).and_return({ jti: 'jti-2' })
    allow(Legion::Extensions::Llm::Fleet::TokenValidator).to receive(:release_replay!)

    expect do
      described_class.call(envelope: failing_envelope, registry: registry)
    end.to raise_error(RuntimeError, /provider unavailable/)

    expect(Legion::Extensions::Llm::Fleet::TokenValidator).to have_received(:release_replay!).with('jti-2')
  end

  describe 'W5/W4 — params and wire-message contract errors' do
    it 'raises ContractError when params contain :model' do
      bad = envelope.merge(params: { messages: [{ role: 'user', content: 'x' }], model: 'other' })
      expect { described_class.call(envelope: bad, registry: registry) }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError, /must not contain model/)
    end

    it 'raises ContractError on a non-Hash wire message' do
      bad = envelope.merge(params: { messages: ['not a message'] })
      expect { described_class.call(envelope: bad, registry: registry) }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError, /serialized Canonical::Message/)
    end

    it 'raises ContractError on a missing per-operation param' do
      bad = envelope.merge(params: {})
      expect { described_class.call(envelope: bad, registry: registry) }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError, /requires the messages param/)
    end

    it 'raises ContractError on an unknown operation' do
      bad = envelope.merge(operation: 'teleport')
      expect { described_class.call(envelope: bad, registry: registry) }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError, /unsupported exact operation/)
    end
  end

  describe 'W6 — fail-closed policy' do
    it 'raises when require_policy is enabled and no policy engine exists' do
      allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
        .with(:fleet, :responder, :require_policy, default: nil).and_return(true)

      expect { described_class.call(envelope: envelope, registry: registry) }
        .to raise_error(described_class::PolicyError, /no policy engine is configured/)
    end
  end
end
