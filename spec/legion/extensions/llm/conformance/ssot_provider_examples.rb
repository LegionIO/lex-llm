# frozen_string_literal: true

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

# Shared conformance examples required unchanged by every SSOT v3 provider PR.
# The including provider spec supplies one `let(:ssot_harness)` implementing the
# harness interface documented in phase-1-lex-llm-additive.md Task 12. These
# examples drive only the public Publisher/Registry API and never call a provider
# actor implementation directly.
RSpec.shared_examples 'an SSOT v3 provider adapter' do
  harness_methods = %i[
    provider_family instance_configs instance_id build_callable build_offering_drafts safe_readiness
    inference_call_count normalize_dispatch_error instance_unavailable_error overloaded_error model_not_ready_error
  ]

  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:configs) { ssot_harness.instance_configs }

  before { registry.reset! }

  def build_key(config)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: ssot_harness.provider_family, instance_id: ssot_harness.instance_id(instance_config: config)
    )
  end

  def publisher_for
    Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: ssot_harness.provider_family)
  end

  def coordinator_for(key)
    Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(instance_key: key, enqueue: ->(**) { true })
  end

  # Claims and (when readiness succeeds) activates one instance through the public
  # Publisher API. Returns the context needed for later assertions.
  def bring_up(config, tier: :local)
    publisher = publisher_for
    key = build_key(config)
    callable = ssot_harness.build_callable(instance_config: config)
    token = publisher.claim_instance(instance_id: key.instance_id, callable: callable, probe_request_handle: coordinator_for(key))
    probe = publisher.readiness_probe_started(instance_id: key.instance_id, publisher_token: token)
    readiness = ssot_harness.safe_readiness(instance_config: config, callable: callable)
    drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
    if readiness.ready?
      publisher.activate_instance_snapshot(instance_id: key.instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe)
    else
      publisher.readiness_failed(instance_id: key.instance_id, probe_token: probe, reason: readiness.reason)
    end
    { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts }
  end

  it 'implements the full harness interface' do
    harness_methods.each do |method_name|
      expect(ssot_harness).to respond_to(method_name), "ssot_harness must implement ##{method_name}"
    end
  end

  it 'supplies two independent instances with distinct ids and distinct callables' do
    expect(configs.size).to eq(2)
    ids = configs.map { |config| ssot_harness.instance_id(instance_config: config) }
    expect(ids.uniq.size).to eq(2)
    callables = configs.map { |config| ssot_harness.build_callable(instance_config: config) }
    expect(callables.first).not_to equal(callables.last)
    expect(ssot_harness.safe_readiness(instance_config: configs.first, callable: callables.first))
      .to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
  end

  it 'publishes distinct identities and independently available lanes for the same model on two instances' do
    a = bring_up(configs[0])
    b = bring_up(configs[1])
    snapshot = registry.snapshot
    expect(snapshot.instance(instance_key: a[:key]).availability.state).to eq(:available)
    expect(snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    lane_a = snapshot.lanes_for(instance_key: a[:key]).first
    lane_b = snapshot.lanes_for(instance_key: b[:key]).first
    expect(lane_a.lane_id).not_to eq(lane_b.lane_id)
    expect(lane_a.offering_id).not_to eq(lane_b.offering_id)
  end

  it 'exposes no selector-visible model or callable before startup readiness' do
    publisher = publisher_for
    key = build_key(configs[0])
    publisher.claim_instance(instance_id: key.instance_id, callable: ssot_harness.build_callable(instance_config: configs[0]), probe_request_handle: coordinator_for(key))
    expect(registry.snapshot.instance(instance_key: key)).to be_nil
    expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
  end

  it 'leaves the instance initializing after an initial readiness failure' do
    publisher = publisher_for
    key = build_key(configs[0])
    token = publisher.claim_instance(instance_id: key.instance_id, callable: ssot_harness.build_callable(instance_config: configs[0]), probe_request_handle: coordinator_for(key))
    probe = publisher.readiness_probe_started(instance_id: key.instance_id, publisher_token: token)
    publisher.readiness_failed(instance_id: key.instance_id, probe_token: probe, reason: 'probe failed')
    expect(registry.snapshot.instance(instance_key: key)).to be_nil
    expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
  end

  it 'performs no provider inference during readiness' do
    context = bring_up(configs[0])
    expect(ssot_harness.inference_call_count(callable: context[:callable])).to eq(0)
  end

  it 'supports complete refresh, complete empty, and failed-refresh retention' do
    context = bring_up(configs[0])
    context[:publisher].replace_instance_snapshot(instance_id: context[:key].instance_id, publisher_token: context[:token], offerings: context[:drafts], sequence: 1)
    expect(registry.snapshot.offerings_for(instance_key: context[:key]).size).to eq(1)
    context[:publisher].replace_instance_snapshot(instance_id: context[:key].instance_id, publisher_token: context[:token], offerings: [], sequence: 2)
    expect(registry.snapshot.offerings_for(instance_key: context[:key])).to be_empty
    expect do
      context[:publisher].replace_instance_snapshot(instance_id: context[:key].instance_id, publisher_token: context[:token], offerings: [], sequence: 2)
    end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::StaleSequenceError)
  end

  it 'preserves offering and lane identity across a tier-only republication' do
    context = bring_up(configs[0], tier: :local)
    before_offering = registry.snapshot.offerings_for(instance_key: context[:key]).first.offering_id
    before_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first.lane_id
    frontier_drafts = ssot_harness.build_offering_drafts(instance_config: configs[0], callable: context[:callable], tier: :frontier)
    context[:publisher].replace_instance_snapshot(instance_id: context[:key].instance_id, publisher_token: context[:token], offerings: frontier_drafts, sequence: 1)
    expect(registry.snapshot.offerings_for(instance_key: context[:key]).first.offering_id).to eq(before_offering)
    expect(registry.snapshot.lanes_for(instance_key: context[:key]).first.lane_id).to eq(before_lane)
  end

  it 'refuses recovery from a stale probe started before the failure' do
    context = bring_up(configs[0])
    stale = context[:publisher].readiness_probe_started(instance_id: context[:key].instance_id, publisher_token: context[:token])
    fresh = context[:publisher].readiness_probe_started(instance_id: context[:key].instance_id, publisher_token: context[:token])
    context[:publisher].readiness_failed(instance_id: context[:key].instance_id, probe_token: fresh, reason: 'down')
    result = context[:publisher].readiness_succeeded(instance_id: context[:key].instance_id, probe_token: stale)
    expect(result.applied).to be(false)
    expect(result.reason).to eq(:stale_probe)
  end

  it 'marks only one exact instance unavailable on a normalized instance_unavailable outcome' do
    a = bring_up(configs[0])
    b = bring_up(configs[1])
    outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.instance_unavailable_error)
    expect(outcome.kind).to eq(:instance_unavailable)
    registry.dispatch_instance_unavailable(instance_key: a[:key], publisher_token_id: a[:token].publisher_token_id, reason: outcome.reason)
    expect(registry.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
    expect(registry.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
  end

  it 'keeps overload and model-not-ready request-local regardless of 503/529 transport status' do
    expect(ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error).kind).to eq(:overloaded)
    expect(ssot_harness.normalize_dispatch_error(error: ssot_harness.model_not_ready_error).kind).to eq(:model_not_ready)
    expect(ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error).kind).not_to eq(:instance_unavailable)
  end

  it 'executes an exact fleet request against only the captured callable' do
    allow(Legion::Extensions::Llm::Fleet::WorkerExecution).to receive_messages(validate_identity!: true, validate_idempotency!: nil)
    context = bring_up(configs[0])
    offering = registry.snapshot.offerings_for(instance_key: context[:key]).first
    envelope = {
      execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: offering.offering_id, provider: ssot_harness.provider_family.to_s,
      provider_instance: context[:key].instance_id, model: offering.model, operation: 'chat', params: { messages: [] }
    }
    Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
    expect(ssot_harness.inference_call_count(callable: context[:callable])).to eq(1)
  end

  it 'rejects provider/model defaults and a nil instance' do
    identity = Legion::Extensions::Llm::Inventory::Identity
    expect { identity::InstanceKey.new(provider_family: ssot_harness.provider_family, instance_id: 'default') }
      .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    expect { identity::InstanceKey.new(provider_family: ssot_harness.provider_family, instance_id: nil) }
      .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
  end

  it 'exposes snapshot each_instance and each_publication_status as ordered blockless enumerators' do
    bring_up(configs[0])
    bring_up(configs[1])
    snapshot = registry.snapshot
    expect(snapshot.each_instance).to be_a(Enumerator)
    expect(snapshot.each_publication_status).to be_a(Enumerator)
    ordered_ids = snapshot.each_instance.map { |record| [record.instance_key.provider_family.to_s, record.instance_key.instance_id] }
    expect(ordered_ids).to eq(ordered_ids.sort)
    expect(snapshot.each_publication_status.map(&:state)).to all(eq(:complete))
  end

  it 'normalizes a dispatch error into a ProviderOutcome on the captured callable itself' do
    callable = ssot_harness.build_callable(instance_config: configs[0])
    expect(callable).to respond_to(:normalize_dispatch_error)
    unavailable = callable.normalize_dispatch_error(error: Legion::Extensions::Llm::ServiceUnavailableError.new('503'))
    expect(unavailable).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    expect(unavailable.kind).to eq(:provider_error)
    expect(unavailable.kind).not_to eq(:instance_unavailable)
    overloaded = callable.normalize_dispatch_error(error: Legion::Extensions::Llm::OverloadedError.new('529'))
    expect(overloaded.kind).to eq(:overloaded)
  end
end
