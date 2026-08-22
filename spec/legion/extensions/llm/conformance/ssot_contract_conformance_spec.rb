# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'
require 'support/ssot_registry_helpers'
require_relative 'conformance'
require_relative 'ssot_contract_examples'

# Kit self-test: the B/F/R shared examples run against a real Provider-derived
# callable, the real Registry, and the real fleet responder/worker — proving
# the examples provider gems will load are executable and meaningful.
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers -- kit host
RSpec.describe 'SSOT v4 contract conformance kit' do
  include SsotRegistryHelpers

  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:family) { :fake_llm }
  let(:key) do
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(provider_family: family, instance_id: 'primary')
  end
  let(:coordinator) { probe_coordinator(key) }
  let(:activated) { true }

  # A real 0.8.0 callable: Provider-derived, canonical in and out, no HTTP.
  let(:callable) do
    Class.new(Legion::Extensions::Llm::Provider) do
      def self.slug = 'kit'
      def self.configuration_requirements = []
      def api_base = 'https://kit.invalid'

      def chat(messages, model:, tools: nil, **_rest)
        enforce_canonical_messages!(messages)
        enforce_canonical_tools!(tools)
        Legion::Extensions::Llm::Canonical::Response.build(text: 'ok', model: model, stop_reason: :end_turn)
      end

      # rubocop:disable Lint/UnusedMethodArgument -- model: mirrors the 0.8.0 callable contract
      def stream_chat(messages, model: nil, tools: nil, **_contract, &block)
        enforce_canonical_messages!(messages)
        enforce_canonical_tools!(tools)
        block&.call(Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'ok', request_id: nil))
        block&.call(Legion::Extensions::Llm::Canonical::Chunk.done(request_id: nil, stop_reason: :end_turn,
                                                                   usage: Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 1)))
        nil
      end
      # rubocop:enable Lint/UnusedMethodArgument

      def count_tokens(messages:, **_contract)
        enforce_canonical_messages!(messages)
        1
      end
    end.new(Legion::Extensions::Llm.config)
  end
  let(:offering_id) do
    registry.snapshot.offerings_for(instance_key: key).first.offering_id
  end
  let(:offering_id_arg) { offering_id }
  let(:instance_key) { key }
  let(:lane_id) { registry.snapshot.lanes_for(instance_key: key).first.lane_id }
  let(:callable_handle) { registry.snapshot.instance(instance_key: key).callable_handle }
  let(:operation_evidence_map) { operation_evidence }
  let(:unknown_value) do
    Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
  end
  let(:exact_envelope_data) do
    {
      request_id: 'req-1', correlation_id: 'corr-1', idempotency_key: 'idem-1',
      operation: 'chat', provider: family.to_s, provider_instance: 'primary', model: 'gemma4',
      params: { messages: [{ role: 'user', content: 'hello' }] },
      reply_to: 'reply.1', message_context: {}, caller: 'e2e', trace_context: {},
      signed_token: 'unsigned', timeout_seconds: 30,
      expires_at: (Time.now.utc + 120).iso8601,
      protocol_version: Legion::Extensions::Llm::Fleet::Protocol::VERSION,
      execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: offering_id
    }
  end
  let(:valid_request_options) do
    {
      routing_key: 'llm.fleet.inference.gemma4.ctx8192',
      request_id: 'req-1', correlation_id: 'corr-1', idempotency_key: 'idem-1',
      operation: :chat, provider: family.to_s, provider_instance: 'primary', model: 'gemma4',
      params: { messages: [{ role: 'user', content: 'hello' }] },
      reply_to: 'reply.1', message_context: {}, caller: 'e2e', trace_context: {},
      signed_token: 'signed.jwt', timeout_seconds: 30, expires_at: '2026-08-20T12:00:00Z',
      protocol_version: Legion::Extensions::Llm::Fleet::Protocol::VERSION,
      execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: offering_id
    }
  end

  before do
    registry.reset!
    claim_and_activate(
      key: key, callable: callable, coordinator: coordinator, model: 'gemma4',
      weight_inputs: { tier: 100, provider: 50, instance: 2, model_or_offering: 1 },
      base_weight: 10_000
    )
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value).and_call_original
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :require_signed_token, default: true).and_return(false)
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :responder, :require_idempotency, default: nil).and_return(false)
    Legion::Extensions::Llm::Fleet::WorkerExecution.reset_idempotency_cache!
    Legion::Extensions::Llm::Fleet::TokenValidator.reset_replay_cache!
  end

  it_behaves_like 'B1 — central canonical enforcement (08 F2)'
  it_behaves_like 'B1b — central canonical tool enforcement (H3)'
  it_behaves_like 'B2 — canonical outputs (05 O5, 08 R2)'
  it_behaves_like 'B3 — operation preservation (PR #189 defect class)'
  it_behaves_like 'B4 — no model re-derivation (PR #45 law)'
  it_behaves_like 'B5 — no weight recomputation (PR #47 defect class)'
  it_behaves_like 'B6 — zero-weight disable (U4)'
  it_behaves_like 'B7 — health authority (RULES 9)'
  it_behaves_like 'B8 — exact execution never downgrades (06 P2/W1)'
  it_behaves_like 'B9 — no silent defaults (06 W5)'
  it_behaves_like 'F1 — envelope round-trip (06 E2)'
  it_behaves_like 'F2 — rehydration identity (06 W4, E01)'
  it_behaves_like 'F3 — signing law (06 S3)'
  it_behaves_like 'F4 — fencing (07 §3)'
  it_behaves_like 'F5 — response envelope (06 E3/E4)'
  it_behaves_like 'F6 — contract errors (06 §5)'
  it_behaves_like 'F7 — retryability (06 F6)'
  it_behaves_like 'R1 — state machine (07 §3)'
  it_behaves_like 'R2 — identity (07 §1)'
  it_behaves_like 'R3 — snapshot law (07 §5)'
  it_behaves_like 'R4 — weight law (07 §4)'
  it_behaves_like 'R5 — callable lifecycle (07 §6)'
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
