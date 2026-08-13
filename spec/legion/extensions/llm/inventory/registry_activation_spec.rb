# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'
require_relative '../../../../support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Inventory::Registry do
  include SsotRegistryHelpers

  inventory = Legion::Extensions::Llm::Inventory
  errors = inventory::Errors

  before { described_class.reset! }

  let(:key) { instance_key }
  let(:callable) { fake_callable }
  let(:coordinator) { probe_coordinator(key) }

  describe 'empty boot snapshot' do
    it 'exposes generation zero and no records' do
      snapshot = described_class.snapshot
      expect(snapshot.generation).to eq(0)
      expect(snapshot.each_lane.to_a).to be_empty
      expect(snapshot.each_offering.to_a).to be_empty
      expect(snapshot.instance(instance_key: key)).to be_nil
    end
  end

  describe 'claim' do
    it 'shows an initializing publication status with no active model or callable' do
      described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      snapshot = described_class.snapshot
      status = snapshot.publication_status(instance_key: key)
      expect(status.state).to eq(:initializing)
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.lanes_for(instance_key: key)).to be_empty
    end

    it 'returns an opaque PublisherToken' do
      token = described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      expect(token).to be_a(inventory::PublisherToken)
    end

    it 'rejects reusing the exact same callable object on re-claim' do
      described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      expect { described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator) }
        .to raise_error(errors::ValidationError)
    end

    it 'fences the superseded token after a fresh re-claim with a distinct callable' do
      token1 = described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      described_class.claim_instance(instance_key: key, callable: fake_callable, probe_request_handle: coordinator)
      expect { described_class.readiness_probe_started(instance_key: key, publisher_token: token1) }
        .to raise_error(errors::FencedPublisherError)
    end
  end

  describe 'startup activation sequence' do
    it 'raises if readiness_succeeded is called before activation' do
      token = described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      probe = described_class.readiness_probe_started(instance_key: key, publisher_token: token)
      expect { described_class.readiness_succeeded(instance_key: key, probe_token: probe) }
        .to raise_error(errors::InvalidTransitionError)
    end

    it 'atomically publishes callable, offerings, lanes, and available on activation' do
      claim_and_activate(key: key, callable: callable, coordinator: coordinator)
      snapshot = described_class.snapshot
      record = snapshot.instance(instance_key: key)
      expect(record).not_to be_nil
      expect(record.availability.state).to eq(:available)
      expect(snapshot.lanes_for(instance_key: key).size).to eq(1)
      expect(snapshot.offerings_for(instance_key: key).size).to eq(1)
      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end

    it 'accepts an explicit complete empty activation as complete, not initializing' do
      token = described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      probe = described_class.readiness_probe_started(instance_key: key, publisher_token: token)
      result = described_class.activate_instance_snapshot(
        publisher_token: token, instance_key: key, offerings: [], sequence: 0, probe_token: probe
      )
      expect(result.applied).to be(true)
      snapshot = described_class.snapshot
      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(snapshot.instance(instance_key: key).offerings_by_id).to eq({})
    end

    it 'consumes the probe token so it cannot be reused' do
      token = described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      probe = described_class.readiness_probe_started(instance_key: key, publisher_token: token)
      described_class.activate_instance_snapshot(publisher_token: token, instance_key: key, offerings: drafts, sequence: 0, probe_token: probe)
      expect { described_class.readiness_succeeded(instance_key: key, probe_token: probe) }
        .to raise_error(errors::InvalidProbeError)
    end

    it 'requires a sequence greater than the claim baseline' do
      token = described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      probe = described_class.readiness_probe_started(instance_key: key, publisher_token: token)
      expect do
        described_class.activate_instance_snapshot(publisher_token: token, instance_key: key, offerings: drafts, sequence: -1, probe_token: probe)
      end.to raise_error(errors::StaleSequenceError)
    end

    it 'increments generation once for a claim' do
      generation = described_class.snapshot.generation
      described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      expect(described_class.snapshot.generation).to eq(generation + 1)
    end
  end

  describe 'initial readiness failure' do
    it 'leaves the instance initializing, exposes no model/callable, and does not mark unavailable' do
      token = described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
      probe = described_class.readiness_probe_started(instance_key: key, publisher_token: token)
      result = described_class.readiness_failed(instance_key: key, probe_token: probe, reason: 'probe failed')
      expect(result.applied).to be(true)
      expect(result.reason).to eq(:initial_readiness_failed)
      snapshot = described_class.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
      expect(snapshot.lanes_for(instance_key: key)).to be_empty
    end
  end

  describe 'no external calls under the mutation mutex' do
    it 'never invokes the callable disconnect or a probe enqueue while activating' do
      enqueue_calls = []
      probing = probe_coordinator(key, enqueue: lambda { |request:|
        enqueue_calls << request
        true
      })
      token = described_class.claim_instance(instance_key: key, callable: callable, probe_request_handle: probing)
      probe = described_class.readiness_probe_started(instance_key: key, publisher_token: token)
      described_class.activate_instance_snapshot(publisher_token: token, instance_key: key, offerings: drafts, sequence: 0, probe_token: probe)
      expect(callable.disconnect_count).to eq(0)
      expect(enqueue_calls).to be_empty
    end
  end
end
