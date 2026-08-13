# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/probe_coordinator'

RSpec.describe Legion::Extensions::Llm::Inventory::ProbeCoordinator do
  inventory = Legion::Extensions::Llm::Inventory
  errors = inventory::Errors

  let(:instance_key) { inventory::Identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'h200') }
  let(:enqueued) { [] }
  let(:enqueue_result) { [true] }
  let(:enqueue) do
    lambda { |request:|
      enqueued << request
      enqueue_result.first
    }
  end
  let(:coordinator) { described_class.new(instance_key: instance_key, enqueue: enqueue) }

  def enqueue_request(revision)
    coordinator.enqueue_probe_request(
      instance_key: instance_key, publisher_token_id: 'ptok:v1:x', unavailable_revision: revision, reason: 'dispatch unavailable'
    )
  end

  it 'does not invoke enqueue at construction (enqueue-only)' do
    coordinator
    expect(enqueued).to be_empty
  end

  it 'enqueues a ProbeRequest built from the reported parameters' do
    enqueue_request(1)
    expect(enqueued.size).to eq(1)
    expect(enqueued.first).to be_a(inventory::ProbeRequest)
    expect(enqueued.first.unavailable_revision).to eq(1)
  end

  it 'rejects a request for a different instance' do
    other = inventory::Identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'helios1')
    expect do
      coordinator.enqueue_probe_request(instance_key: other, publisher_token_id: 'ptok:v1:x', unavailable_revision: 1, reason: 'x')
    end.to raise_error(errors::ValidationError)
  end

  it 'coalesces duplicate-revision requests to a single enqueue' do
    enqueue_request(5)
    enqueue_request(5)
    expect(enqueued.size).to eq(1)
    expect(coordinator.pending?(unavailable_revision: 5)).to be(true)
  end

  it 'retains only the greatest pending revision without re-enqueuing' do
    enqueue_request(5)
    enqueue_request(7)
    expect(enqueued.size).to eq(1)
    expect(coordinator.pending?(unavailable_revision: 7)).to be(true)
    expect(coordinator.pending?(unavailable_revision: 5)).to be(false)
  end

  it 'retains pending and returns false when enqueue fails, without inline readiness' do
    enqueue_result[0] = false
    expect(enqueue_request(3)).to be(false)
    expect(coordinator.pending?(unavailable_revision: 3)).to be(true)
  end

  describe 'single flight and post-finish re-enqueue' do
    it 'admits one flight, holds newer work, and re-enqueues the greatest pending on finish' do
      enqueue_request(5)
      first = enqueued.last
      expect(coordinator.begin_probe(request: first)).to be(true)
      expect(coordinator.in_flight?).to be(true)

      # A newer revision arrives during the flight: retained, not enqueued.
      enqueue_request(7)
      expect(enqueued.size).to eq(1)

      coordinator.finish_probe(request: first)
      expect(coordinator.in_flight?).to be(false)
      expect(enqueued.size).to eq(2)
      expect(enqueued.last.unavailable_revision).to eq(7)
    end

    it 'rejects a second begin while a flight is active' do
      enqueue_request(5)
      expect(coordinator.begin_probe(request: enqueued.last)).to be(true)
      expect(coordinator.begin_probe(request: nil)).to be(false)
    end

    it 'supports the cadence (nil) begin/finish form and rejects a mismatched finish form' do
      mismatched = inventory::ProbeRequest.new(
        instance_key: instance_key, publisher_token_id: 'ptok:v1:x', unavailable_revision: 1, reason: 'x'
      )
      expect(coordinator.begin_probe(request: nil)).to be(true)
      expect { coordinator.finish_probe(request: mismatched) }.to raise_error(errors::InvalidTransitionError)
      expect { coordinator.finish_probe(request: nil) }.not_to raise_error
      expect(coordinator.in_flight?).to be(false)
    end

    it 'only admits a begin for the exact greatest pending request' do
      enqueue_request(5)
      stale = enqueued.last
      enqueue_request(9) # replaces pending; stale is no longer greatest
      expect(coordinator.begin_probe(request: stale)).to be(false)
    end
  end
end
