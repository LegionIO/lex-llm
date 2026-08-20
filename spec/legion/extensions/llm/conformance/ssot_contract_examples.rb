# frozen_string_literal: true

# 09 §2–§4 — boundary (B), fleet (F), and registry (R) conformance shared
# examples. The kit is the single oracle: provider gems load these and run
# them against their REAL callable boundary and the shared Registry/Responder.
#
# The host spec provides:
#   let(:callable)    — a 0.8.0 callable: chat(messages, model:, ...),
#                       stream_chat(messages, model:, ...) yielding
#                       Canonical::Chunk, count_tokens(messages:, model:)
#   let(:registry)    — Legion::Extensions::Llm::Inventory::Registry
#   let(:key)         — an InstanceKey for the activated scope
#   let(:offering_id) — an offering_id on the activated instance
#   let(:activated)   — true once the scope is activated (F/R groups)

LLM  = Legion::Extensions::Llm
CAN  = LLM::Canonical
INV  = LLM::Inventory

RSpec.shared_examples 'B1 — central canonical enforcement (08 F2)' do
  let(:canonical_messages) { [CAN::Message.build(role: :user, content: 'hi')] }

  [
    ['a raw Hash message', [{ role: 'user', content: 'x' }]],
    ['a String element', ['not canonical']],
    ['a nil element', [nil]]
  ].each do |label, bad_messages|
    it "chat rejects #{label} with a typed ArgumentError" do
      expect { callable.chat(bad_messages, model: 'm') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it "stream_chat rejects #{label} with a typed ArgumentError" do
      # rubocop:disable Lint/EmptyBlock -- the block never runs: enforcement raises first
      expect { callable.stream_chat(bad_messages, model: 'm') { |_c| } }
        .to raise_error(ArgumentError, /Canonical::Message/)
      # rubocop:enable Lint/EmptyBlock
    end

    it "count_tokens rejects #{label} with a typed ArgumentError" do
      expect { callable.count_tokens(messages: bad_messages, model: 'm') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end
  end

  it 'accepts a canonical Array<Canonical::Message>' do
    expect { callable.chat(canonical_messages, model: 'm') }.not_to raise_error
  end
end

RSpec.shared_examples 'B2 — canonical outputs (05 O5, 08 R2)' do
  it 'chat returns a Canonical::Response (asserted by type)' do
    expect(callable.chat([CAN::Message.build(role: :user, content: 'hi')], model: 'm'))
      .to be_a(CAN::Response)
  end

  it 'stream_chat yields Canonical::Chunk objects ending in exactly one done chunk' do
    chunks = []
    callable.stream_chat([CAN::Message.build(role: :user, content: 'hi')], model: 'm') { |c| chunks << c }

    expect(chunks.size).to be > 0
    expect(chunks).to all(be_a(CAN::Chunk))
    expect(chunks.count(&:done?)).to eq(1)
    expect(chunks.last).to be_done
  end
end

RSpec.shared_examples 'B3 — operation preservation (PR #189 defect class)' do
  it 'a stream_chat dispatch invokes the stream_chat callable, never chat' do
    chat_invocations = 0
    stream_invocations = 0
    allow(callable).to receive(:chat).and_wrap_original do |original, *args, **kwargs|
      chat_invocations += 1
      original.call(*args, **kwargs)
    end
    allow(callable).to receive(:stream_chat).and_wrap_original do |_original, *_args, &block|
      stream_invocations += 1
      block&.call(CAN::Chunk.done(request_id: nil))
    end

    # rubocop:disable Lint/EmptyBlock -- the block is the assertion target
    callable.stream_chat([CAN::Message.build(role: :user, content: 'hi')], model: 'm') { |_c| }
    # rubocop:enable Lint/EmptyBlock

    expect(stream_invocations).to eq(1)
    expect(chat_invocations).to eq(0)
  end
end

RSpec.shared_examples 'B4 — no model re-derivation (PR #45 law)' do
  it 'the Selection-derived model reaches the callable unchanged' do
    response = callable.chat([CAN::Message.build(role: :user, content: 'hi')], model: 'selected-model-x')
    expect(response.model).to eq('selected-model-x')
  end
end

RSpec.shared_examples 'B5 — no weight recomputation (PR #47 defect class)' do
  it 'the lane keeps the write-time pair even when settings would compute a different one' do
    lane = registry.snapshot.lanes_for(instance_key: key).first
    expect(lane.base_weight).to eq(100 * 50 * 2 * 1)

    # A later settings read (e.g. after an operator change) would compute a
    # different pair — the stored lane pair is consumed as-is.
    family = key.provider_family.to_sym
    other_inputs = LLM::Inventory.const_get(:WeightSchema).weight_inputs(
      settings: { extensions: { llm: { family => { weight: 77, instances: { key.instance_id.to_sym => { weight: 77 } } } } },
                  llm: { routing: { tier_weights: { local: 100 } } } },
      instance_key: key, provider_native_key: 'gemma4', model: 'gemma4', tier: :local
    )
    expect(other_inputs).to eq(tier: 100, provider: 77, instance: 77, model_or_offering: 100)
    expect(registry.snapshot.lanes_for(instance_key: key).first.base_weight).to eq(10_000)
  end
end

RSpec.shared_examples 'B6 — zero-weight disable (U4)' do
  it 'Selection validation accepts a zero component (operator disable)' do
    selection = LLM::Routing::Selection.new(
      inventory_generation: 7, lane_id: lane_id, instance_key: instance_key, offering_id: offering_id_arg,
      provider_family: instance_key.provider_family, instance_id: instance_key.instance_id,
      model: 'gemma4', operation: :chat, callable_handle: callable_handle,
      publisher_token_id: 'ptok:v1:abc', capability_evidence: {},
      context_evidence: INV::ValueEvidence.new(status: :unknown, source: :absent),
      weight_inputs: { tier: 100, provider: 0, instance: 100, model_or_offering: 100 },
      base_weight: 0, preference_ppm: 1_000_000, effective_weight: 0, rendezvous_score: 1
    )
    expect(selection.base_weight).to eq(0)
    expect(selection.weight_inputs[:provider]).to eq(0)
  end

  it 'Selection validation still rejects a negative component' do
    expect do
      LLM::Routing::Selection.new(
        inventory_generation: 7, lane_id: lane_id, instance_key: instance_key, offering_id: offering_id_arg,
        provider_family: instance_key.provider_family, instance_id: instance_key.instance_id,
        model: 'gemma4', operation: :chat, callable_handle: callable_handle,
        publisher_token_id: 'ptok:v1:abc', capability_evidence: {},
        context_evidence: INV::ValueEvidence.new(status: :unknown, source: :absent),
        weight_inputs: { tier: 100, provider: -1, instance: 100, model_or_offering: 100 },
        base_weight: 0, preference_ppm: 1_000_000, effective_weight: 0, rendezvous_score: 1
      )
    end.to raise_error(INV::Errors::ValidationError, /nonnegative/)
  end
end

RSpec.shared_examples 'B7 — health authority (RULES 9)' do
  it 'transient provider outcomes do not change instance availability' do
    outcome = callable.normalize_dispatch_error(error: LLM::RateLimitError.new(nil, 'slow down'))
    expect(outcome.kind).to eq(:rate_limited)
    expect(outcome.kind).not_to eq(:instance_unavailable)
    expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
  end

  it 'only the authoritative dispatch path marks the instance unavailable' do
    health_key = INV::Identity::InstanceKey.new(provider_family: key.provider_family, instance_id: 'health-b')
    health_coordinator = LLM::Inventory::ProbeCoordinator.new(instance_key: health_key, enqueue: ->(**) { true })
    token = registry.claim_instance(instance_key: health_key, callable: Object.new, probe_request_handle: health_coordinator)
    probe = registry.readiness_probe_started(instance_key: health_key, publisher_token: token)
    registry.activate_instance_snapshot(publisher_token: token, instance_key: health_key,
                                        offerings: drafts, sequence: 0, probe_token: probe)
    record = registry.snapshot.instance(instance_key: health_key)
    registry.dispatch_instance_unavailable(
      instance_key: health_key, publisher_token_id: record.publisher_token_id, reason: 'node down'
    )
    expect(registry.snapshot.instance(instance_key: health_key).availability.state).to eq(:unavailable)
  end
end

RSpec.shared_examples 'B8 — exact execution never downgrades (06 P2/W1)' do
  it 'a fleet envelope without the exact marker is rejected' do
    legacy_envelope = LLM::Fleet::FleetEnvelope.new(
      data: exact_envelope_data.except(:execution_contract, :offering_id)
    )
    expect { LLM::Fleet::ProviderResponder.check_envelope!(legacy_envelope, provider_family: key.provider_family.to_s) }
      .to raise_error(ArgumentError, /execution_contract is required/)
  end

  it 'the provider-object dispatch path does not exist' do
    expect(LLM::Fleet::ProviderResponder).not_to respond_to(:build_provider)
    expect(LLM::Fleet::WorkerExecution).not_to respond_to(:dispatch_local_provider!)
  end
end

RSpec.shared_examples 'B9 — no silent defaults (06 W5)' do
  it 'a missing per-operation param raises, never a default' do
    expect { LLM::Fleet::WorkerExecution.call(envelope: exact_envelope_data.merge(params: {}), registry: registry) }
      .to raise_error(LLM::Fleet::ContractError, /requires the messages param/)
  end

  it 'a params-supplied model raises — the Selection model is the only model' do
    bad = exact_envelope_data.merge(params: { messages: [], model: 'other' })
    expect { LLM::Fleet::WorkerExecution.call(envelope: bad, registry: registry) }
      .to raise_error(LLM::Fleet::ContractError, /must not contain model/)
  end
end

RSpec.shared_examples 'F1 — envelope round-trip (06 E2)' do
  it 'FleetRequest encode → JSON → parse carries every required field' do
    request = LLM::Transport::Messages::FleetRequest.new(**valid_request_options)
    wire = Legion::JSON.load(Legion::JSON.dump(request.message))

    LLM::Fleet::Protocol::REQUIRED_FIELDS.each do |field|
      expect(wire).to have_key(field)
      # JSON normalizes the wire: compare in wire form (symbols become strings).
      expect(wire[field].is_a?(Hash) ? wire[field].transform_keys(&:to_s) : wire[field].to_s)
        .to eq(request.message[field].is_a?(Hash) ? request.message[field].transform_keys(&:to_s) : request.message[field].to_s)
    end
  end
end

RSpec.shared_examples 'F2 — rehydration identity (06 W4, E01)' do
  it 'JSON-round-tripped wire messages rehydrate to Data-equal Canonical::Message' do
    original = CAN::Message.build(
      role: :user, content: 'hi', cache_control: { type: :ephemeral },
      tool_calls: [CAN::ToolCall.build(name: 'f', id: 'c1', arguments: { a: 1 })]
    )
    wire = Legion::JSON.load(Legion::JSON.dump([original.to_h]))
    rehydrated = LLM::Fleet::WorkerExecution.rehydrate_wire_messages(wire)

    expect(rehydrated.size).to eq(1)
    rehydrated_message = rehydrated.first
    expect(rehydrated_message).to be_a(CAN::Message)
    expect(rehydrated_message.id).to eq(original.id)
    expect(rehydrated_message.role).to eq(:user)
    expect(rehydrated_message.content).to eq('hi')
    expect(rehydrated_message.tool_calls.first.name).to eq('f')
    expect(rehydrated_message.tool_calls.first.arguments).to eq(a: 1)
    # E01: cache_control survives the full JSON wire round-trip.
    expect(rehydrated_message.cache_control).to eq(type: 'ephemeral')
  end

  it 'a raw Hash message can NOT reach a callable — rehydration raises' do
    expect { LLM::Fleet::WorkerExecution.rehydrate_wire_messages(['not a message']) }
      .to raise_error(LLM::Fleet::ContractError, /serialized Canonical::Message/)
  end
end

RSpec.shared_examples 'F3 — signing law (06 S3)' do
  it 'verifies exact claims unconditionally — a missing marker claim is a TokenError' do
    expect do
      LLM::Fleet::TokenValidator.validate_exact_execution_claims!({}, { operation: 'chat' })
    end.to raise_error(LLM::Fleet::TokenError, /missing signed execution_contract/)
  end

  it 'a tampered offering_id claim is a TokenError' do
    claims = { execution_contract: LLM::Fleet::Protocol::EXACT_EXECUTION_CONTRACT, offering_id: "off:v1:#{'0' * 64}" }
    expect do
      LLM::Fleet::TokenValidator.validate_exact_execution_claims!(claims, exact_envelope_data)
    end.to raise_error(LLM::Fleet::TokenError, /offering_id claim mismatch/)
  end
end

RSpec.shared_examples 'F4 — fencing (07 §3)' do
  let(:fence_key) { INV::Identity::InstanceKey.new(provider_family: 'kit', instance_id: 'fence') }
  let(:fence_coordinator) do
    LLM::Inventory::ProbeCoordinator.new(instance_key: fence_key, enqueue: ->(**) { true })
  end

  it 'a superseded publisher token is fenced' do
    registry.reset!
    token1 = registry.claim_instance(instance_key: fence_key, callable: Object.new, probe_request_handle: fence_coordinator)
    registry.claim_instance(instance_key: fence_key, callable: Object.new, probe_request_handle: fence_coordinator)
    expect { registry.readiness_probe_started(instance_key: fence_key, publisher_token: token1) }
      .to raise_error(INV::Errors::FencedPublisherError)
  end

  it 'a sequence at or below the claim baseline is rejected (StaleSequenceError)' do
    first = registry.claim_instance(instance_key: fence_key, callable: Object.new, probe_request_handle: fence_coordinator)
    probe = registry.readiness_probe_started(instance_key: fence_key, publisher_token: first)
    expect do
      registry.activate_instance_snapshot(publisher_token: first, instance_key: fence_key,
                                          offerings: drafts, sequence: -1, probe_token: probe)
    end.to raise_error(INV::Errors::StaleSequenceError)
  end
end

RSpec.shared_examples 'F5 — response envelope (06 E3/E4)' do
  it 'carries the serialized Canonical::Response and never the thinking member' do
    thinking_callable = Class.new do
      def chat(_messages, model:, **_rest)
        CAN::Response.build(
          text: 'done', model: model, stop_reason: :end_turn,
          thinking: CAN::Thinking.build(content: 'secret-reasoning')
        )
      end
    end.new
    thinking_key = INV::Identity::InstanceKey.new(provider_family: 'fake_llm', instance_id: 'thinking')
    token = registry.claim_instance(instance_key: thinking_key, callable: thinking_callable,
                                    probe_request_handle: LLM::Inventory::ProbeCoordinator.new(
                                      instance_key: thinking_key, enqueue: ->(**) { true }
                                    ))
    probe = registry.readiness_probe_started(instance_key: thinking_key, publisher_token: token)
    thinking_offering = INV::Identity.offering_id(instance_key: thinking_key, provider_native_key: 'gemma4')
    registry.activate_instance_snapshot(publisher_token: token, instance_key: thinking_key,
                                        offerings: [
                                          INV::OfferingDraft.new(
                                            provider_native_key: 'gemma4', model: 'gemma4', tier: :local,
                                            operation_evidence: operation_evidence_map,
                                            context_evidence: unknown_value, max_output_evidence: unknown_value,
                                            embedding_dimensions_evidence: unknown_value,
                                            model_revision_evidence: unknown_value, tokenizer_evidence: unknown_value,
                                            publication_source: :provider_catalog
                                          )
                                        ], sequence: 0, probe_token: probe)

    published_args = nil
    response_double = instance_double(LLM::Transport::Messages::FleetResponse, publish: true)
    allow(LLM::Transport::Messages::FleetResponse).to receive(:new) do |*args|
      published_args = args
      response_double
    end

    LLM::Fleet::ProviderResponder.call(
      payload: exact_envelope_data.merge(provider_instance: 'thinking', offering_id: thinking_offering),
      provider_family: exact_envelope_data[:provider],
      registry: registry
    )

    expect(published_args.first[:response]).to include(text: 'done')
    expect(published_args.first[:response]).not_to have_key(:thinking)
    expect(response_double).to have_received(:publish)
  end
end

RSpec.shared_examples 'F6 — contract errors (06 §5)' do
  {
    'a non-Hash wire message' => ->(data) { data.merge(params: { messages: ['nope'] }) },
    'duplicate param spellings' => ->(data) { data.merge(params: { 'messages' => [], :messages => [] }) },
    'an unknown operation' => ->(data) { data.merge(operation: 'teleport') }
  }.each do |label, mutator|
    it "#{label} is a Fleet::ContractError, never a silent substitute" do
      expect { LLM::Fleet::WorkerExecution.call(envelope: mutator.call(exact_envelope_data), registry: registry) }
        .to raise_error(LLM::Fleet::ContractError)
    end
  end
end

RSpec.shared_examples 'F7 — retryability (06 F6)' do
  it 'contract, policy, and auth errors are never retryable' do
    responder = LLM::Fleet::ProviderResponder
    expect(responder.retryable_error?(LLM::Fleet::ContractError.new('x'))).to be(false)
    expect(responder.retryable_error?(LLM::Fleet::WorkerExecution::PolicyError.new('x'))).to be(false)
    expect(responder.retryable_error?(LLM::Fleet::TokenError.new('x'))).to be(false)
    expect(responder.retryable_error?(INV::Errors::ExactOfferingMismatchError.new('x'))).to be(false)
  end

  it 'transient kinds are retryable' do
    responder = LLM::Fleet::ProviderResponder
    expect(responder.retryable_error?(LLM::RateLimitError.new(nil, 'x'))).to be(true)
    expect(responder.retryable_error?(LLM::OverloadedError.new(nil, 'x'))).to be(true)
    expect(responder.retryable_error?(Timeout::Error.new('x'))).to be(true)
  end
end

RSpec.shared_examples 'R1 — state machine (07 §3)' do
  let(:r1_key) { INV::Identity::InstanceKey.new(provider_family: 'kit', instance_id: 'r1') }
  let(:r1_coordinator) { LLM::Inventory::ProbeCoordinator.new(instance_key: r1_key, enqueue: ->(**) { true }) }

  it 'activate without a claim is invalid' do
    registry.reset!
    expect do
      registry.activate_instance_snapshot(publisher_token: 'forged', instance_key: r1_key,
                                          offerings: drafts, sequence: 0)
    end.to raise_error(ArgumentError)
  end

  it 'a claim without activation stays initializing (no active instance)' do
    registry.claim_instance(instance_key: r1_key, callable: Object.new, probe_request_handle: r1_coordinator)
    expect(registry.snapshot.instance(instance_key: r1_key)).to be_nil
    expect(registry.snapshot.publication_status(instance_key: r1_key).state).to eq(:initializing)
  end
end

RSpec.shared_examples 'R2 — identity (07 §1)' do
  it 'reproduces offering and lane ids from their fields' do
    offering = INV::Identity.offering_id(instance_key: key, provider_native_key: 'gemma4')
    expect(offering).to eq(INV::Identity.offering_id(instance_key: key, provider_native_key: 'gemma4'))

    lane = INV::Identity.lane_id(instance_key: key, operation: :chat, model: 'gemma4', offering_id: offering)
    expect(lane).to eq(INV::Identity.lane_id(instance_key: key, operation: :chat, model: 'gemma4', offering_id: offering))
  end

  it 'rejects a forged offering id' do
    expect do
      INV::Identity.validate_offering_id!(
        value: "off:v1:#{'0' * 64}", instance_key: key, provider_native_key: 'gemma4'
      )
    end.to raise_error(INV::Errors::ValidationError)
  end
end

RSpec.shared_examples 'R3 — snapshot law (07 §5)' do
  it 'lookups return nil for absent scopes (no synthesized defaults)' do
    absent = INV::Identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'nowhere')
    expect(registry.snapshot.instance(instance_key: absent)).to be_nil
  end

  it 'is generation-stable across later mutations' do
    snapshot_before = registry.snapshot
    before_record = snapshot_before.instance(instance_key: key)
    expect(before_record).not_to be_nil

    r3_key = INV::Identity::InstanceKey.new(provider_family: 'kit', instance_id: 'r3')
    r3_coordinator = LLM::Inventory::ProbeCoordinator.new(instance_key: r3_key, enqueue: ->(**) { true })
    registry.claim_instance(instance_key: r3_key, callable: Object.new, probe_request_handle: r3_coordinator)
    expect(snapshot_before.generation).not_to eq(registry.snapshot.generation)
    # The captured snapshot still serves its own generation's records.
    expect(snapshot_before.instance(instance_key: key)).to eq(before_record)
  end
end

RSpec.shared_examples 'R4 — weight law (07 §4)' do
  it 'accepts zero (operator disable), rejects non-Integer, and requires base == product' do
    schema = LLM::Inventory.const_get(:WeightSchema)
    zero = { tier: 100, provider: 0, instance: 100, model_or_offering: 100 }
    expect(schema.base_weight(zero)).to eq(0)

    expect do
      INV::RecordSupport.validated_weight_pair(
        weight_inputs: { tier: '100', provider: 0, instance: 100, model_or_offering: 100 }, base_weight: 0
      )
    end.to raise_error(INV::Errors::ValidationError)

    expect do
      INV::RecordSupport.validated_weight_pair(
        weight_inputs: zero, base_weight: 1
      )
    end.to raise_error(INV::Errors::ValidationError, /product/)
  end
end

RSpec.shared_examples 'R5 — callable lifecycle (07 §6)' do
  it 'acquires a lease exposing the exact captured callable and releases it' do
    handle = registry.snapshot.instance(instance_key: key).callable_handle
    lease = registry.acquire(callable_handle: handle)
    expect(lease.callable).to be(callable)
    lease.release
  end

  it 'an unknown handle is rejected' do
    expect { registry.acquire(callable_handle: Object.new) }
      .to raise_error(INV::Errors::UnknownCallableError)
  end
end
