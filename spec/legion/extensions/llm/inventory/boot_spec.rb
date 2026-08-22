# frozen_string_literal: true

require 'spec_helper'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Test-only namespace anchor so this boot spec's file path aligns with its
        # describe target under RSpec/SpecFilePathFormat. It adds no runtime
        # behavior and exists only in the test load path.
        module Boot; end
      end
    end
  end
end

# Proves the SSOT v3 contract is wired by `require "legion/extensions/llm"`
# alone, with no legion-llm, LegionIO, transport, database, or timer dependency.
RSpec.describe Legion::Extensions::Llm::Inventory::Boot do
  inventory = Legion::Extensions::Llm::Inventory

  def build_callable
    Class.new do
      def disconnect; end
    end.new
  end

  def probe_handle(key)
    Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(instance_key: key, enqueue: ->(**) { true })
  end

  def full_lifecycle(key)
    registry = Legion::Extensions::Llm::Inventory::Registry
    token = registry.claim_instance(instance_key: key, callable: build_callable, probe_request_handle: probe_handle(key))
    probe = registry.readiness_probe_started(instance_key: key, publisher_token: token)
    registry.activate_instance_snapshot(publisher_token: token, instance_key: key, offerings: [], sequence: 0, probe_token: probe)
  end

  before { inventory::Registry.reset! }

  it 'loads without Legion::LLM or LegionIO present' do
    expect(defined?(Legion::LLM)).to be_nil
    expect(defined?(LegionIO)).to be_nil
  end

  it 'exposes every require-order constant' do
    %i[
      Errors ImmutableValue Identity Evidence CallableHandle DispatchLease ProbeToken ProbeRequest
      ProbeCoordinator PublisherToken OfferingDraft LaneRecord AvailabilityFact
      ReadinessResult InstanceRecord PublicationStatus MutationResult Snapshot Registry Publisher
    ].each { |const| expect(inventory.const_defined?(const)).to be(true), "missing Inventory::#{const}" }
    %i[AttemptTargetKey QuotaDomainKey Exclusion Selection Rejection BodyModelHintDecision ProviderOutcome].each do |const|
      expect(Legion::Extensions::Llm::Routing.const_defined?(const)).to be(true), "missing Routing::#{const}"
    end
  end

  it 'runs claim -> probe -> activate -> snapshot after only requiring the extension' do
    key = inventory::Identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'h200')
    result = full_lifecycle(key)
    expect(result.applied).to be(true)
    expect(inventory::Registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
  end

  it 'creates no new thread during boot or a mutation' do
    baseline = Thread.list.size
    key = inventory::Identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'thread-check')
    full_lifecycle(key)
    expect(Thread.list.size).to eq(baseline)
  end

  it 'removes the legacy Types aliases (0.8.0 rip)' do
    expect(Legion::Extensions::Llm.const_defined?(:Types, false)).to be(false)
    expect(Legion::Extensions::Llm::Inventory.const_defined?(:InstanceKey, false)).to be(false)
  end

  it 'preserves the optional transport message registration (autoload or loaded)' do
    expect(Legion::Extensions::Llm::Transport::Messages.const_defined?(:FleetResponse, false)).to be(true)
  end
end
