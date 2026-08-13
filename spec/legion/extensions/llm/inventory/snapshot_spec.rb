# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'
require_relative '../../../../support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Inventory::Snapshot do
  include SsotRegistryHelpers

  registry = Legion::Extensions::Llm::Inventory::Registry

  before { registry.reset! }

  let(:key_a) { instance_key(instance: 'h200') }
  let(:key_b) { instance_key(instance: 'helios1') }

  def activate_both
    claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
    claim_and_activate(key: key_b, callable: fake_callable, coordinator: probe_coordinator(key_b))
    registry.snapshot
  end

  describe 'lookups' do
    it 'returns the frozen record or nil and never synthesizes a default' do
      snapshot = activate_both
      record = snapshot.instance(instance_key: key_a)
      expect(record).to be_frozen
      expect(snapshot.instance(instance_key: instance_key(instance: 'absent'))).to be_nil
      expect(snapshot.lane(lane_id: 'lane:v1:missing')).to be_nil
      expect(snapshot.offering(offering_id: 'off:v1:missing')).to be_nil
    end

    it 'only lists activated instances but keeps initializing claims in publication status' do
      claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      registry.claim_instance(instance_key: key_b, callable: fake_callable, probe_request_handle: probe_coordinator(key_b))
      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key_a)).not_to be_nil
      expect(snapshot.instance(instance_key: key_b)).to be_nil
      expect(snapshot.publication_status(instance_key: key_b).state).to eq(:initializing)
    end
  end

  describe 'ordering and iteration' do
    it 'returns frozen lanes_for/offerings_for arrays ordered by id' do
      snapshot = activate_both
      lanes = snapshot.lanes_for(instance_key: key_a)
      expect(lanes).to be_frozen
      expect(lanes.map(&:lane_id)).to eq(lanes.map(&:lane_id).sort)
    end

    it 'each_lane/each_offering yield in id order and return an Enumerator without a block' do
      snapshot = activate_both
      expect(snapshot.each_lane).to be_a(Enumerator)
      expect(snapshot.each_offering).to be_a(Enumerator)
      expect(snapshot.each_lane.map(&:lane_id)).to eq(snapshot.each_lane.map(&:lane_id).sort)
    end
  end

  describe 'structural immutability of an older snapshot' do
    it 'does not observe a later record or generation mutation' do
      claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      old = registry.snapshot
      old_generation = old.generation
      claim_and_activate(key: key_b, callable: fake_callable, coordinator: probe_coordinator(key_b))
      expect(old.generation).to eq(old_generation)
      expect(old.instance(instance_key: key_b)).to be_nil
      expect(registry.snapshot.instance(instance_key: key_b)).not_to be_nil
    end

    it 'lets a captured callable handle move to retiring after fencing (lifecycle exception)' do
      token = claim_and_activate(key: key_a, callable: fake_callable, coordinator: probe_coordinator(key_a))
      captured = registry.snapshot.instance(instance_key: key_a).callable_handle
      expect(captured.state).to eq(:active)
      registry.remove_instance(instance_key: key_a, publisher_token: token)
      expect(captured.state).to eq(:disposed)
    end
  end
end
