# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/publisher'
require_relative '../../../../support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Inventory::Publisher do
  include SsotRegistryHelpers

  inventory = Legion::Extensions::Llm::Inventory

  before { inventory::Registry.reset! }

  # Records adapter invocations; returns a configurable outcome.
  let(:adapter_calls) { [] }
  let(:adapter_outcome) { [:applied] }
  let(:adapter) do
    calls = adapter_calls
    outcome = adapter_outcome
    Object.new.tap do |obj|
      obj.define_singleton_method(:sync_snapshot) do |snapshot:, instance_key:, mutation_reason:|
        calls << { snapshot: snapshot, instance_key: instance_key, mutation_reason: mutation_reason }
        outcome.first
      end
    end
  end

  let(:publisher) { described_class.new(provider_family: :vllm, compatibility_adapter: adapter) }
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
  end

  describe 'post-commit compatibility projection' do
    it 'invokes the adapter after a successful claim and applied mutation with the committed snapshot' do
      full_activate(publisher)
      expect(adapter_calls.map { |c| c[:mutation_reason] }).to eq(%i[claimed activated])
      # The adapter sees the already-committed snapshot on activation.
      activation_call = adapter_calls.last
      expect(activation_call[:snapshot].instance(instance_key: instance_key).availability.state).to eq(:available)
      expect(activation_call[:instance_key]).to eq(instance_key)
    end

    it 'does not invoke the adapter for a non-applied (stale) mutation' do
      token = full_activate(publisher)
      adapter_calls.clear
      # Supersede the publisher, then a stale replace returns applied: false.
      publisher.claim_instance(instance_id: 'h200', callable: fake_callable, probe_request_handle: probe_coordinator(instance_key))
      adapter_calls.clear
      result = publisher.replace_instance_snapshot(instance_id: 'h200', publisher_token: token, offerings: drafts, sequence: 9)
      expect(result.applied).to be(false)
      expect(adapter_calls).to be_empty
    end

    it 'never changes the local result when the adapter returns :failed' do
      adapter_outcome[0] = :failed
      token = publisher.claim_instance(instance_id: 'h200', callable: fake_callable, probe_request_handle: probe_coordinator(instance_key))
      expect(token).to be_a(inventory::PublisherToken)
    end

    it 'never changes the local result when the adapter raises' do
      failing = Object.new.tap do |obj|
        obj.define_singleton_method(:sync_snapshot) { |**| raise 'boom' }
      end
      pub = described_class.new(provider_family: :vllm, compatibility_adapter: failing)
      expect { pub.claim_instance(instance_id: 'h200', callable: fake_callable, probe_request_handle: probe_coordinator(instance_key)) }
        .not_to raise_error
    end

    it 'invokes the adapter again on the next applied cadence mutation' do
      token = full_activate(publisher)
      adapter_calls.clear
      publisher.replace_instance_snapshot(instance_id: 'h200', publisher_token: token, offerings: drafts(native: 'gemma5', model: 'gemma5'), sequence: 1)
      expect(adapter_calls.map { |c| c[:mutation_reason] }).to eq(%i[snapshot_replaced])
    end
  end

  describe 'without a compatibility adapter' do
    it 'performs no projection and returns the plain registry results' do
      result = full_activate(plain_publisher)
      expect(result).to be_a(inventory::PublisherToken)
    end
  end
end
