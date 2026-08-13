# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'
require_relative '../../../../support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Inventory::Registry do
  include SsotRegistryHelpers

  errors = Legion::Extensions::Llm::Inventory::Errors

  before { described_class.reset! }

  let(:key) { instance_key }
  let(:callable) { fake_callable }
  let(:coordinator) { probe_coordinator(key) }
  let(:token) { claim_and_activate(key: key, callable: callable, coordinator: coordinator, sequence: 0) }

  it 'replaces the complete offering set with a strictly increasing sequence' do
    token
    result = described_class.replace_instance_snapshot(
      publisher_token: token, instance_key: key, offerings: drafts(native: 'gemma5', model: 'gemma5'), sequence: 1
    )
    expect(result.applied).to be(true)
    expect(result.reason).to eq(:snapshot_replaced)
    offerings = described_class.snapshot.offerings_for(instance_key: key)
    expect(offerings.map(&:provider_native_key)).to eq(['gemma5'])
  end

  it 'preserves the exact availability fact across replacement' do
    token
    before_fact = described_class.snapshot.instance(instance_key: key).availability
    described_class.replace_instance_snapshot(publisher_token: token, instance_key: key, offerings: drafts, sequence: 1)
    after_fact = described_class.snapshot.instance(instance_key: key).availability
    expect(after_fact.availability_revision).to eq(before_fact.availability_revision)
    expect(after_fact.state).to eq(:available)
  end

  it 'rejects a non-increasing sequence' do
    token
    expect { described_class.replace_instance_snapshot(publisher_token: token, instance_key: key, offerings: drafts, sequence: 0) }
      .to raise_error(errors::StaleSequenceError)
  end

  it 'treats an empty array as an authoritative complete empty snapshot' do
    token
    described_class.replace_instance_snapshot(publisher_token: token, instance_key: key, offerings: [], sequence: 1)
    expect(described_class.snapshot.offerings_for(instance_key: key)).to be_empty
    expect(described_class.snapshot.instance(instance_key: key).availability.state).to eq(:available)
  end

  it 'leaves the prior root untouched when draft validation fails' do
    token
    generation = described_class.snapshot.generation
    duplicate = drafts + drafts # two drafts with the same provider_native_key
    expect { described_class.replace_instance_snapshot(publisher_token: token, instance_key: key, offerings: duplicate, sequence: 1) }
      .to raise_error(errors::ValidationError)
    expect(described_class.snapshot.generation).to eq(generation)
    expect(described_class.snapshot.offerings_for(instance_key: key).size).to eq(1)
  end

  it 'returns a stale publisher result for a superseded token' do
    token
    described_class.claim_instance(instance_key: key, callable: fake_callable, probe_request_handle: coordinator)
    result = described_class.replace_instance_snapshot(publisher_token: token, instance_key: key, offerings: drafts, sequence: 5)
    expect(result.applied).to be(false)
    expect(result.reason).to eq(:stale_publisher)
  end
end
