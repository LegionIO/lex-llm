# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Fleet::ProviderResponder do
  include SsotRegistryHelpers

  let(:protocol) { Legion::Extensions::Llm::Fleet::Protocol }
  let(:key) { instance_key(family: 'ollama', instance: 'default') }
  let(:callable) do
    Class.new do
      def chat(messages, model:, **_params)
        Legion::Extensions::Llm::Canonical::Response.build(
          text: "chat #{model} #{messages.first.text}",
          model: model,
          stop_reason: :end_turn,
          usage: Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 1, output_tokens: 2)
        )
      end
    end.new
  end
  let(:offering_id) do
    Legion::Extensions::Llm::Inventory::Registry.snapshot.offerings_for(instance_key: key).first.offering_id
  end
  let(:payload) { payload_for(offering_id) }

  def payload_for(offering_id)
    {
      request_id: 'req-1',
      correlation_id: 'corr-1',
      idempotency_key: 'idem-1',
      operation: 'chat',
      provider: 'ollama',
      provider_instance: 'default',
      model: 'llama3',
      params: { messages: [{ role: 'user', content: 'hello' }] },
      reply_to: 'reply.queue',
      message_context: { conversation_id: 'conv-1' },
      caller: { identity: 'user:test' },
      trace_context: { trace_id: 'trace-1' },
      signed_token: 'unsigned',
      timeout_seconds: 30,
      expires_at: (Time.now.utc + 30).iso8601,
      protocol_version: protocol::VERSION,
      execution_contract: protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: offering_id
    }
  end

  before do
    Legion::Extensions::Llm::Inventory::Registry.reset!
    claim_and_activate(key: key, callable: callable, coordinator: probe_coordinator(key), model: 'llama3')
    Legion::Extensions::Llm::Fleet::WorkerExecution.reset_idempotency_cache!
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value).and_call_original
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :require_signed_token, default: true).and_return(false)
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :responder, :require_idempotency, default: nil).and_return(false)
  end

  it 'does not require the legion-llm namespace on responder nodes' do
    hide_const('Legion::LLM') if defined?(Legion::LLM)

    expect(defined?(Legion::LLM)).to be_nil
    expect(described_class).to respond_to(:call)
  end

  it 'dispatches the exact request through the registry and publishes the serialized Canonical::Response (E3)' do
    response_message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetResponse, publish: true)
    published_args = nil
    allow(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to receive(:new) do |*args|
      published_args = args
      response_message
    end

    response = described_class.call(
      payload: payload,
      provider_family: 'ollama',
      registry: Legion::Extensions::Llm::Inventory::Registry
    )

    expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(response.text).to eq('chat llama3 hello')
    expect(published_args.first).to include(
      request_id: 'req-1',
      correlation_id: 'corr-1',
      provider: 'ollama',
      provider_instance: 'default',
      model: 'llama3',
      execution_contract: protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: offering_id
    )
    published = published_args.first[:response]
    expect(published).to include(text: 'chat llama3 hello', stop_reason: :end_turn)
    # The envelope carries the serialized Canonical::Response; the Usage member
    # is the canonical object (JSON encoding at publish serializes it per as_json).
    expect(published[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
    expect(published[:usage].input_tokens).to eq(1)
    expect(published[:usage].output_tokens).to eq(2)
    expect(response_message).to have_received(:publish)
  end

  it 'rejects legacy fleet protocol fields before execution (P4)' do
    expect do
      described_class.call(
        payload: payload.merge(request_type: 'chat'),
        provider_family: 'ollama',
        registry: Legion::Extensions::Llm::Inventory::Registry
      )
    end.to raise_error(ArgumentError, /request_type/)
  end

  it 'reports whether a provider instance is enabled for fleet responses' do
    expect(described_class.enabled_for?(default: { fleet: { respond_to_requests: true } })).to be(true)
    expect(described_class.enabled_for?(default: { fleet: { respond_to_requests: false } })).to be(false)
    expect(described_class.enabled_for?(-> { { default: { fleet: { respond_to_requests: 'true' } } } })).to be(true)
  end

  it 'raises an actionable configuration error when fleet transport messages cannot load' do
    allow(Legion::Extensions::Llm::Transport::Messages).to receive(:const_get)
      .with(:FleetResponse).and_raise(NameError, 'missing transport')

    expect do
      described_class.transport_message_class(:FleetResponse)
    end.to raise_error(described_class::ConfigurationError, /fleet responder transport unavailable/)
  end

  describe 'P2 — exact-only execution contract' do
    it 'rejects a missing marker (legacy v2 tolerance is deleted)' do
      legacy = payload_for(offering_id).except(:execution_contract)
      envelope = described_class.parse_payload(legacy)
      expect { described_class.check_envelope!(envelope, provider_family: 'ollama') }
        .to raise_error(ArgumentError, /execution_contract is required/)
    end

    it 'rejects an unknown nonempty marker' do
      envelope = described_class.parse_payload(payload.merge(execution_contract: 'made_up'))
      expect { described_class.check_envelope!(envelope, provider_family: 'ollama') }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError, /execution_contract must be/)
    end

    it 'requires the exact fields for the exact marker' do
      envelope = described_class.parse_payload(payload.merge(offering_id: nil))
      expect { described_class.check_envelope!(envelope, provider_family: 'ollama') }
        .to raise_error(ArgumentError, /offering_id is required/)
    end

    it 'rejects a false marker before dispatch' do
      envelope = described_class.parse_payload(payload.merge(execution_contract: false))
      expect { described_class.check_envelope!(envelope, provider_family: 'ollama') }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError, /execution_contract must be/)
    end

    it 'accepts a complete exact envelope' do
      envelope = described_class.parse_payload(payload)
      expect { described_class.check_envelope!(envelope, provider_family: 'ollama') }.not_to raise_error
    end
  end

  describe 'P3 — explicit protocol version' do
    it 'rejects a missing protocol_version (no default fill)' do
      envelope = described_class.parse_payload(payload.except(:protocol_version))
      expect { described_class.check_envelope!(envelope, provider_family: 'ollama') }
        .to raise_error(ArgumentError, /protocol_version is required/)
    end

    it 'rejects a mismatched protocol_version' do
      envelope = described_class.parse_payload(payload.merge(protocol_version: 2))
      expect { described_class.check_envelope!(envelope, provider_family: 'ollama') }
        .to raise_error(ArgumentError, /protocol_version must be 3/)
    end
  end

  describe 'E1 — wire normalization' do
    it 'raises on a wrong-shape payload (the silent {} fallback is deleted)' do
      expect { described_class.parse_payload(42) }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError, /expected Hash or String, got Integer/)
    end

    it 'wraps Hash payloads through the single FleetEnvelope entry' do
      envelope = described_class.parse_payload({ 'request_id' => 'r1', protocol_version: 3 })
      expect(envelope).to be_a(Legion::Extensions::Llm::Fleet::FleetEnvelope)
      expect(envelope.request_id).to eq('r1')
    end

    it 'reads false values for both key spellings' do
      symbol_envelope = Legion::Extensions::Llm::Fleet::FleetEnvelope.new(data: { execution_contract: false })
      string_envelope = Legion::Extensions::Llm::Fleet::FleetEnvelope.new(data: { 'execution_contract' => false })

      expect(symbol_envelope[:execution_contract]).to be(false)
      expect(string_envelope[:execution_contract]).to be(false)
    end
  end

  describe 'F6 — retryability derived from the ProviderOutcome kind table' do
    it 'never retries contract, policy, auth, or classification errors' do
      expect(described_class.retryable_error?(Legion::Extensions::Llm::Fleet::ContractError.new('x'))).to be(false)
      expect(described_class.retryable_error?(Legion::Extensions::Llm::Fleet::WorkerExecution::PolicyError.new('x'))).to be(false)
      expect(described_class.retryable_error?(Legion::Extensions::Llm::Fleet::TokenError.new('x'))).to be(false)
      expect(described_class.retryable_error?(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError.new('x'))).to be(false)
      expect(described_class.retryable_error?(described_class::ConfigurationError.new('x'))).to be(false)
    end

    it 'retries transient provider kinds only' do
      expect(described_class.retryable_error?(Legion::Extensions::Llm::RateLimitError.new(nil, 'x'))).to be(true)
      expect(described_class.retryable_error?(Legion::Extensions::Llm::OverloadedError.new(nil, 'x'))).to be(true)
      expect(described_class.retryable_error?(Timeout::Error.new('x'))).to be(true)
      expect(described_class.retryable_error?(Legion::Extensions::Llm::UnauthorizedError.new(nil, 'x'))).to be(false)
    end
  end

  describe 'G5 — thinking never crosses the fleet' do
    it 'excludes thinking from the response envelope exactly once at the builder' do
      thinking_callable = Class.new do
        def chat(_messages, model:, **)
          Legion::Extensions::Llm::Canonical::Response.build(
            text: 'done',
            model: model,
            stop_reason: :end_turn,
            thinking: Legion::Extensions::Llm::Canonical::Thinking.build(content: 'secret-reasoning')
          )
        end
      end.new
      key2 = instance_key(family: 'ollama', instance: 'thinking')
      Legion::Extensions::Llm::Inventory::Registry.reset!
      claim_and_activate(key: key2, callable: thinking_callable, coordinator: probe_coordinator(key2), model: 'llama3')
      thinking_offering = Legion::Extensions::Llm::Inventory::Registry
                          .snapshot.offerings_for(instance_key: key2).first.offering_id

      response_message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetResponse, publish: true)
      published_args = nil
      allow(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to receive(:new) do |*args|
        published_args = args
        response_message
      end

      described_class.call(
        payload: payload_for(thinking_offering).merge(provider_instance: 'thinking'),
        provider_family: 'ollama',
        registry: Legion::Extensions::Llm::Inventory::Registry
      )

      expect(published_args.first[:response]).not_to have_key(:thinking)
    end
  end
end
