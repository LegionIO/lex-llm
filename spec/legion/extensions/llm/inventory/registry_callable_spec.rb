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
  let(:token) { claim_and_activate(key: key, callable: callable, coordinator: coordinator) }
  let(:handle) { token && described_class.snapshot.instance(instance_key: key).callable_handle }

  it 'acquires a lease that exposes the exact captured callable' do
    lease = described_class.acquire(callable_handle: handle)
    expect(lease.callable).to equal(callable)
    lease.release
  end

  it 'rejects acquiring a non-CallableHandle' do
    token
    expect { described_class.acquire(callable_handle: Object.new) }.to raise_error(errors::UnknownCallableError)
  end

  it 'lets an already-acquired lease finish after the instance is removed, disconnecting exactly once' do
    lease = described_class.acquire(callable_handle: handle)
    described_class.remove_instance(instance_key: key, publisher_token: token)
    expect(handle.state).to eq(:retiring)
    expect(callable.disconnect_count).to eq(0)
    # the in-flight lease still works
    expect(lease.callable).to equal(callable)
    lease.release
    expect(handle.state).to eq(:disposed)
    expect(callable.disconnect_count).to eq(1)
  end

  it 'blocks a new acquisition against a retired handle' do
    described_class.acquire(callable_handle: handle) # keep one lease so removal leaves it retiring
    described_class.remove_instance(instance_key: key, publisher_token: token)
    expect { described_class.acquire(callable_handle: handle) }.to raise_error(errors::StaleCallableError)
  end

  it 'removes an idle instance and disposes its handle' do
    handle
    described_class.remove_instance(instance_key: key, publisher_token: token)
    expect(handle.state).to eq(:disposed)
    expect(described_class.snapshot.instance(instance_key: key)).to be_nil
  end

  it 'returns already_removed for a second removal' do
    handle
    described_class.remove_instance(instance_key: key, publisher_token: token)
    result = described_class.remove_instance(instance_key: key, publisher_token: token)
    expect(result.applied).to be(false)
    expect(result.reason).to eq(:already_removed)
  end
end
