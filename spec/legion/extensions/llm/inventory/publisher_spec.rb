# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/publisher'
require_relative '../../../../support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Inventory::Publisher do
  include SsotRegistryHelpers

  inventory = Legion::Extensions::Llm::Inventory

  before { inventory::Registry.reset! }

  let(:plain_publisher) { described_class.new(provider_family: :vllm) }

  def full_activate(pub)
    token = pub.claim_instance(instance_id: 'h200', callable: fake_callable, probe_request_handle: probe_coordinator(instance_key))
    probe = pub.readiness_probe_started(instance_id: 'h200', publisher_token: token)
    pub.activate_instance_snapshot(instance_id: 'h200', publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe)
    token
  end

  describe 'delegation' do
    it 'claims, activates, and exposes the snapshot through the fixed provider family' do
      full_activate(plain_publisher)
      record = plain_publisher.snapshot.instance(instance_key: instance_key)
      expect(record.availability.state).to eq(:available)
      expect(record.instance_key.provider_family).to eq(:vllm)
    end

    it 'delegates removal with the publisher token' do
      token = full_activate(plain_publisher)
      result = plain_publisher.remove_instance(instance_id: 'h200', publisher_token: token)
      expect(result.applied).to be(true)
      expect(plain_publisher.snapshot.instance(instance_key: instance_key)).to be_nil
    end

    it 'M7: exposes no legacy dual-sink seam (the compatibility adapter is deleted)' do
      expect { described_class.new(provider_family: :vllm, compatibility_adapter: Object.new) }
        .to raise_error(ArgumentError, /compatibility_adapter/)
      expect(described_class.instance_method(:initialize).parameters).not_to include(%i[key compatibility_adapter])
    end

    it 'replaces the same scope when a new claim supersedes the publisher' do
      token = full_activate(plain_publisher)
      plain_publisher.claim_instance(instance_id: 'h200', callable: fake_callable, probe_request_handle: probe_coordinator(instance_key))
      result = plain_publisher.replace_instance_snapshot(instance_id: 'h200', publisher_token: token, offerings: drafts, sequence: 9)
      expect(result.applied).to be(false)
    end
  end

  describe 'secondary physical_id' do
    it 'carries the physical id on the committed key while identity stays the config name' do
      token = plain_publisher.claim_instance(
        instance_id: 'h200', callable: fake_callable,
        probe_request_handle: probe_coordinator(instance_key), physical_id: '10.0.0.1:8000/ak:abc123'
      )
      probe = plain_publisher.readiness_probe_started(instance_id: 'h200', publisher_token: token)
      plain_publisher.activate_instance_snapshot(
        instance_id: 'h200', publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      keyed_with_physical = inventory::Identity::InstanceKey.new(
        provider_family: 'vllm', instance_id: 'h200', physical_id: '10.0.0.1:8000/ak:abc123'
      )
      record = plain_publisher.snapshot.instance(instance_key: keyed_with_physical)
      expect(record).not_to be_nil
      expect(record.instance_key.physical_id).to eq('10.0.0.1:8000/ak:abc123')

      # Identity lookup without the physical id finds the same committed instance.
      expect(plain_publisher.snapshot.instance(instance_key: instance_key)).to eq(record)
    end

    it 'replaces the same scope when the physical id changes for the same config name' do
      old_token = plain_publisher.claim_instance(
        instance_id: 'h200', callable: fake_callable,
        probe_request_handle: probe_coordinator(instance_key), physical_id: '10.0.0.1:8000/ak:abc123'
      )
      new_token = plain_publisher.claim_instance(
        instance_id: 'h200', callable: fake_callable,
        probe_request_handle: probe_coordinator(instance_key), physical_id: '10.0.0.9:9000'
      )

      # The old publisher is superseded on the SAME scope (no parallel scope).
      expect { plain_publisher.readiness_probe_started(instance_id: 'h200', publisher_token: old_token) }
        .to raise_error(inventory::Errors::FencedPublisherError)
      expect(plain_publisher.readiness_probe_started(instance_id: 'h200', publisher_token: new_token))
        .to be_a(inventory::ProbeToken)
    end
  end
end
