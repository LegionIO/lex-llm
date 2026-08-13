# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'
require_relative '../../../../support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Inventory::Registry do
  include SsotRegistryHelpers

  errors = Legion::Extensions::Llm::Inventory::Errors

  before { described_class.reset! }

  let(:key_a) { instance_key(instance: 'h200') }
  let(:key_b) { instance_key(instance: 'helios1') }

  def revision_of(key)
    described_class.snapshot.instance(instance_key: key)&.availability&.availability_revision
  end

  def state_of(key)
    described_class.snapshot.instance(instance_key: key)&.availability&.state
  end

  def probe(token, key)
    described_class.readiness_probe_started(instance_key: key, publisher_token: token)
  end

  describe 'ordinary readiness success while available' do
    it 'records telemetry without changing availability revision or eligibility' do
      token = claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      expect(revision_of(key_a)).to eq(1)
      result = described_class.readiness_succeeded(instance_key: key_a, probe_token: probe(token, key_a))
      expect(result.reason).to eq(:readiness_observed)
      expect(revision_of(key_a)).to eq(1)
      expect(state_of(key_a)).to eq(:available)
    end
  end

  describe 'exact-instance isolation' do
    it 'keeps two instances of the same provider and model independent through failure and recovery' do
      token_a = claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      claim_and_activate(key: key_b, callable: fake_callable, coordinator: probe_coordinator(key_b))

      described_class.readiness_failed(instance_key: key_a, probe_token: probe(token_a, key_a), reason: 'a failed')
      expect(state_of(key_a)).to eq(:unavailable)
      expect(state_of(key_b)).to eq(:available)

      recover = described_class.readiness_succeeded(instance_key: key_a, probe_token: probe(token_a, key_a))
      expect(recover.reason).to eq(:instance_recovered)
      expect(state_of(key_a)).to eq(:available)
      expect(state_of(key_b)).to eq(:available)
    end
  end

  describe 'availability revisions' do
    it 'increments the availability revision on each successive unavailable transition' do
      token = claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      described_class.readiness_failed(instance_key: key_a, probe_token: probe(token, key_a), reason: 'first')
      first = revision_of(key_a)
      described_class.readiness_failed(instance_key: key_a, probe_token: probe(token, key_a), reason: 'second')
      expect(revision_of(key_a)).to eq(first + 1)
    end
  end

  describe 'stale and superseded probes cannot recover' do
    it 'refuses recovery from a probe started before the failure' do
      token = claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      stale = probe(token, key_a) # started at availability revision 1, before the failure
      described_class.readiness_failed(instance_key: key_a, probe_token: probe(token, key_a), reason: 'failed')
      result = described_class.readiness_succeeded(instance_key: key_a, probe_token: stale)
      expect(result.applied).to be(false)
      expect(result.reason).to eq(:stale_probe)
      expect(state_of(key_a)).to eq(:unavailable)
    end

    it 'recovers with a probe started after the failure' do
      token = claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      described_class.readiness_failed(instance_key: key_a, probe_token: probe(token, key_a), reason: 'failed')
      fresh = probe(token, key_a) # started at the new (unavailable) revision
      result = described_class.readiness_succeeded(instance_key: key_a, probe_token: fresh)
      expect(result.reason).to eq(:instance_recovered)
      expect(state_of(key_a)).to eq(:available)
    end
  end

  describe 'dispatch-reported instance unavailable' do
    it 'marks only the exact active instance unavailable using the non-secret token id and enqueues a probe' do
      enqueued = []
      coordinator_a = probe_coordinator(key_a, enqueue: lambda { |request:|
        enqueued << request
        true
      })
      token_a = claim_and_activate(key: key_a, callable: fake_callable, coordinator: coordinator_a)
      claim_and_activate(key: key_b, callable: fake_callable, coordinator: probe_coordinator(key_b))

      result = described_class.dispatch_instance_unavailable(
        instance_key: key_a, publisher_token_id: token_a.publisher_token_id, reason: 'normalized instance_unavailable'
      )
      expect(result.applied).to be(true)
      expect(result.reason).to eq(:instance_unavailable)
      expect(state_of(key_a)).to eq(:unavailable)
      expect(state_of(key_b)).to eq(:available)
      expect(enqueued.size).to eq(1)
      expect(enqueued.first.instance_key).to eq(key_a)
    end

    it 'rejects a stale (non-current) publisher token id without mutating' do
      claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      result = described_class.dispatch_instance_unavailable(
        instance_key: key_a, publisher_token_id: 'ptok:v1:not-current', reason: 'x'
      )
      expect(result.applied).to be(false)
      expect(result.reason).to eq(:stale_publisher)
      expect(state_of(key_a)).to eq(:available)
    end

    it 'is a process-local method that accepts the public token id, not the secret PublisherToken' do
      token = claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      # Passing the secret token object where a String id is expected must not authorize the transition.
      result = described_class.dispatch_instance_unavailable(
        instance_key: key_a, publisher_token_id: token, reason: 'x'
      )
      expect(result.applied).to be(false)
      expect(state_of(key_a)).to eq(:available)
    end

    it 'is invalid for an initializing instance' do
      token = described_class.claim_instance(instance_key: key_a, callable: fake_callable, probe_request_handle: probe_coordinator(key_a))
      expect do
        described_class.dispatch_instance_unavailable(instance_key: key_a, publisher_token_id: token.publisher_token_id, reason: 'x')
      end.to raise_error(errors::InvalidTransitionError)
    end
  end

  describe 'global instance-unavailable filters all of that instance lanes' do
    it 'marks every lane of one instance unavailable without touching another instance' do
      two_models = drafts(native: 'gemma4', model: 'gemma4') +
                   drafts(native: 'gemma5', model: 'gemma5')
      token_a = described_class.claim_instance(instance_key: key_a, callable: fake_callable, probe_request_handle: probe_coordinator(key_a))
      probe_a = described_class.readiness_probe_started(instance_key: key_a, publisher_token: token_a)
      described_class.activate_instance_snapshot(publisher_token: token_a, instance_key: key_a, offerings: two_models, sequence: 0, probe_token: probe_a)
      claim_and_activate(key: key_b, callable: fake_callable, coordinator: probe_coordinator(key_b))

      described_class.dispatch_instance_unavailable(instance_key: key_a, publisher_token_id: token_a.publisher_token_id, reason: 'down')
      expect(state_of(key_a)).to eq(:unavailable)
      # lanes remain visible for diagnosis on the instance record
      expect(described_class.snapshot.lanes_for(instance_key: key_a).size).to eq(2)
      expect(state_of(key_b)).to eq(:available)
    end
  end
end
