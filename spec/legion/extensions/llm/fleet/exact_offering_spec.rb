# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/token_validator'
require 'legion/extensions/llm/fleet/protocol'
require_relative '../../../../support/ssot_registry_helpers'

module Legion
  module Extensions
    module Llm
      module Fleet
        # Test-only anchor aligning this spec's path with its describe target.
        module ExactOffering; end
      end
    end
  end
end

RSpec.describe Legion::Extensions::Llm::Fleet::ExactOffering do
  include SsotRegistryHelpers

  inventory = Legion::Extensions::Llm::Inventory
  errors = inventory::Errors
  worker = Legion::Extensions::Llm::Fleet::WorkerExecution
  protocol = Legion::Extensions::Llm::Fleet::Protocol
  token_validator = Legion::Extensions::Llm::Fleet::TokenValidator

  let(:recording_callable) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def disconnect; end

      def chat(messages:, model:, **rest)
        @calls << { op: :chat, messages: messages, model: model, rest: rest }
        { content: 'exact-ok' }
      end

      def stream_chat(messages:, model:, **rest)
        @calls << { op: :stream_chat, messages: messages, model: model, rest: rest }
        { content: 'stream-exact-ok' }
      end

      def count_tokens(messages:, model:, **rest)
        @calls << { op: :count_tokens, messages: messages, model: model, rest: rest }
        1
      end

      def embed(text:, model:, **rest)
        @calls << { op: :embed, text: text, model: model, rest: rest }
        { content: 'embed-ok' }
      end
    end.new
  end

  let(:key) { instance_key(family: 'vllm', instance: 'h200') }

  before do
    inventory::Registry.reset!
    claim_and_activate(
      key: key, callable: recording_callable, coordinator: probe_coordinator(key),
      supported: %i[chat stream_chat count_tokens]
    )
    allow(worker).to receive_messages(validate_identity!: true, validate_idempotency!: nil)
  end

  def offering_id
    Legion::Extensions::Llm::Inventory::Identity.offering_id(instance_key: key, provider_native_key: 'gemma4')
  end

  def exact_envelope(**overrides)
    {
      execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT, offering_id: offering_id,
      provider: 'vllm', provider_instance: 'h200', model: 'gemma4', operation: 'chat',
      params: { messages: [] }
    }.merge(overrides)
  end

  def handle_reference_count
    Legion::Extensions::Llm::Inventory::Registry.snapshot.instance(instance_key: key).callable_handle.reference_count
  end

  describe 'exact dispatch' do
    it 'invokes only the captured callable and releases the lease' do
      worker.call(envelope: exact_envelope, registry: inventory::Registry)
      expect(recording_callable.calls.map { |c| c[:op] }).to eq([:chat])
      expect(handle_reference_count).to eq(0)
    end

    it 'requires exactly one of registry or provider' do
      expect { worker.call(envelope: exact_envelope, registry: inventory::Registry, provider: Object.new) }
        .to raise_error(worker::PolicyError)
      expect { worker.call(envelope: exact_envelope) }.to raise_error(worker::PolicyError)
    end

    it 'releases the lease even when the callable raises' do
      allow(recording_callable).to receive(:chat).and_raise(StandardError, 'boom')
      expect { worker.call(envelope: exact_envelope, registry: inventory::Registry) }.to raise_error(StandardError)
      expect(handle_reference_count).to eq(0)
    end

    it 'rejects a mismatched offering_id, model, operation, and absent instance before invocation' do
      expect { worker.call(envelope: exact_envelope(offering_id: "off:v1:#{'0' * 64}"), registry: inventory::Registry) }
        .to raise_error(errors::ExactOfferingMismatchError)
      expect { worker.call(envelope: exact_envelope(model: 'other'), registry: inventory::Registry) }
        .to raise_error(errors::ExactOfferingMismatchError)
      expect { worker.call(envelope: exact_envelope(operation: 'embed'), registry: inventory::Registry) }
        .to raise_error(errors::ExactOfferingMismatchError)
      expect { worker.call(envelope: exact_envelope(provider_instance: 'absent'), registry: inventory::Registry) }
        .to raise_error(errors::ExactOfferingMismatchError)
      expect(recording_callable.calls).to be_empty
    end

    it 'rejects duplicate String/Symbol param spellings' do
      expect { worker.call(envelope: exact_envelope(params: { 'messages' => [], :messages => [] }), registry: inventory::Registry) }
        .to raise_error(errors::ExactOfferingMismatchError)
    end

    it 'rejects a params-supplied model (envelope model is the only model)' do
      expect { worker.call(envelope: exact_envelope(params: { messages: [], model: 'x' }), registry: inventory::Registry) }
        .to raise_error(errors::ExactOfferingMismatchError)
    end

    it 'rejects a missing required operation param' do
      expect { worker.call(envelope: exact_envelope(params: {}), registry: inventory::Registry) }
        .to raise_error(errors::ExactOfferingMismatchError)
    end

    it 'passes an explicit empty messages array and forwards unknown kwargs' do
      worker.call(envelope: exact_envelope(params: { messages: [], temperature: 0.2 }), registry: inventory::Registry)
      call = recording_callable.calls.first
      expect(call[:messages]).to eq([])
      expect(call[:rest]).to eq(temperature: 0.2)
    end

    it 'rehydrates JSON-round-tripped messages before every message operation' do
      raw_messages = [
        { role: 'system', content: 'follow the rules' },
        {
          role: 'assistant', content: '',
          tool_calls: [{ id: 'call-1', name: 'lookup', arguments: { query: 'status' } }]
        },
        { role: 'tool', tool_call_id: 'call-1', content: 'clean' },
        { role: 'user', content: 'continue' }
      ]

      %w[chat stream_chat count_tokens].each do |operation|
        wire_envelope = Legion::JSON.load(
          Legion::JSON.dump(exact_envelope(operation: operation, params: { messages: raw_messages }))
        )
        worker.call(envelope: wire_envelope, registry: inventory::Registry)
      end

      expect(recording_callable.calls.map { |call| call[:op] }).to eq(%i[chat stream_chat count_tokens])
      recording_callable.calls.each do |call|
        expect(call[:messages]).to all(be_a(Legion::Extensions::Llm::Canonical::Message))
        expect(call[:messages].map(&:role)).to eq(%i[system assistant tool user])
        expect(call[:messages][1].tool_calls.first.name).to eq('lookup')
        expect(call[:messages][2].tool_call_id).to eq('call-1')
      end
    end
  end

  describe 'registry-backed legacy v2 resolution' do
    def activate_two_offerings
      registry = Legion::Extensions::Llm::Inventory::Registry
      registry.reset!
      token = registry.claim_instance(instance_key: key, callable: recording_callable, probe_request_handle: probe_coordinator(key))
      probe = registry.readiness_probe_started(instance_key: key, publisher_token: token)
      two = drafts(native: 'a', model: 'gemma4') + drafts(native: 'b', model: 'gemma4')
      registry.activate_instance_snapshot(publisher_token: token, instance_key: key, offerings: two, sequence: 0, probe_token: probe)
    end

    it 'refuses zero matches' do
      envelope = { provider: 'vllm', provider_instance: 'h200', model: 'nope', operation: 'chat', params: { messages: [] } }
      expect { worker.call(envelope: envelope, registry: inventory::Registry) }.to raise_error(errors::ExactOfferingMismatchError)
    end

    it 'refuses multiple matches' do
      activate_two_offerings
      envelope = { provider: 'vllm', provider_instance: 'h200', model: 'gemma4', operation: 'chat', params: { messages: [] } }
      expect { worker.call(envelope: envelope, registry: inventory::Registry) }.to raise_error(errors::AmbiguousLegacyOfferingError)
    end
  end

  describe 'legacy provider path still operates' do
    it 'dispatches through the provider object without a registry' do
      provider = recording_callable
      envelope = { operation: 'chat', model: 'gemma4', params: { messages: [] } }
      worker.call(envelope: envelope, provider: provider)
      expect(recording_callable.calls.map { |c| c[:op] }).to eq([:chat])
    end
  end

  describe 'TokenValidator exact signed claims' do
    it 'requires both exact scalar claims to be signed and to match when the marker is present' do
      envelope = { execution_contract: protocol::EXACT_EXECUTION_CONTRACT, offering_id: offering_id }
      good = { execution_contract: protocol::EXACT_EXECUTION_CONTRACT, offering_id: offering_id }
      expect { token_validator.validate_exact_execution_claims!(good, envelope) }.not_to raise_error

      missing = { execution_contract: protocol::EXACT_EXECUTION_CONTRACT }
      expect { token_validator.validate_exact_execution_claims!(missing, envelope) }
        .to raise_error(Legion::Extensions::Llm::Fleet::TokenError)

      mismatched = { execution_contract: protocol::EXACT_EXECUTION_CONTRACT, offering_id: "off:v1:#{'0' * 64}" }
      expect { token_validator.validate_exact_execution_claims!(mismatched, envelope) }
        .to raise_error(Legion::Extensions::Llm::Fleet::TokenError)
    end

    it 'is a no-op for a legacy v2 envelope without the marker' do
      expect { token_validator.validate_exact_execution_claims!({}, { operation: 'chat' }) }.not_to raise_error
    end
  end
end
