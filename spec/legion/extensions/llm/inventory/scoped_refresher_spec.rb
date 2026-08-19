# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/scoped_refresher'
require 'legion/extensions/llm/inventory/registry'
require_relative '../../../../support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Inventory::ScopedRefresher do
  describe '.compose_id' do
    it 'builds a 5-part colon-separated id (G22)' do
      id = described_class.compose_id(
        tier: :direct, provider_family: :vllm, instance_id: :apollo,
        type: :inference, model: 'gemma-12b'
      )
      expect(id).to eq('direct:vllm:apollo:inference:gemma-12b')
      expect(id.split(':').size).to eq(5)
    end
  end

  describe '#tick write-then-delete-orphans (G7)' do
    let(:inventory_writes)  { [] }
    let(:inventory_deletes) { [] }

    before do
      stub_const('Legion::LLM::Inventory', Module.new)
      allow(Legion::LLM::Inventory).to receive(:write_lane) { |lane:, **| inventory_writes << lane[:id] }
      allow(Legion::LLM::Inventory).to receive(:delete_lane) { |id:, **| inventory_deletes << id }
    end

    def make_actor(models)
      klass = Class.new do
        include Legion::Extensions::Llm::Inventory::ScopedRefresher

        def self.every_seconds = 60
        def scope_key = { provider: :test }
        def credential_hash = 'testhash'

        attr_accessor :models

        def compute_lanes_for_scope
          @models.map do |m|
            {
              id: Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(
                tier: :direct, provider_family: :test, instance_id: :default,
                type: :inference, model: m
              ),
              tier: :direct, provider_family: :test, instance_id: :default,
              model: m, type: :inference
            }
          end
        end

        def log = Logger.new(File::NULL)
        def handle_exception(_err, **) = nil
      end
      actor = klass.new
      actor.models = models
      actor
    end

    it 'writes new lanes before deleting orphans (zero-results race window eliminated)' do
      actor = make_actor(%w[gemma-12b])
      actor.tick
      expect(inventory_writes).to include('direct:test:default:inference:gemma-12b')
    end

    it 'deletes orphaned lanes (present on previous tick, absent on current)' do
      actor = make_actor(%w[gemma-12b gemma-31b])
      actor.tick
      actor.models = %w[gemma-31b]
      actor.tick
      expect(inventory_deletes).to include('direct:test:default:inference:gemma-12b')
      expect(inventory_writes.last).to eq('direct:test:default:inference:gemma-31b')
    end

    it 'writes nothing when compute raises, leaving previous lanes in place' do
      actor = make_actor(%w[gemma-12b])
      actor.tick
      allow(actor).to receive(:compute_lanes_for_scope).and_raise(StandardError, 'net error')
      actor.tick
      expect(inventory_writes.count('direct:test:default:inference:gemma-12b')).to eq(1)
      expect(inventory_deletes).to be_empty
    end
  end

  describe 'auth-failure cooldown circuit (P2 commit 3)' do
    let(:cache_store) { {} }
    let(:cooldown_key) { 'llm_auth_failed:testhash' }

    before do
      stub_const('Legion::LLM::Inventory', Module.new)
      allow(Legion::LLM::Inventory).to receive(:write_lane)
      allow(Legion::LLM::Inventory).to receive(:delete_lane)

      stub_const('Legion::Cache::Local', Module.new)
      allow(Legion::Cache::Local).to receive(:get) { |k| cache_store[k] }
      allow(Legion::Cache::Local).to receive(:set) do |k, v, **|
        cache_store[k] = v
      end
    end

    def make_auth_fail_actor(**)
      klass = Class.new do
        include Legion::Extensions::Llm::Inventory::ScopedRefresher

        def self.every_seconds = 60
        def scope_key = { provider: :test }
        def credential_hash = 'testhash'

        attr_accessor :should_raise, :raise_error

        def compute_lanes_for_scope
          raise @raise_error if @should_raise

          []
        end

        def log
          @log ||= begin
            l = Object.new
            def l.warn(_msg) = nil
            def l.info(_msg) = nil
            def l.debug(_msg) = nil
            l
          end
        end

        def handle_exception(_err, **) = nil
      end
      actor = klass.new
      actor.should_raise = false
      actor.raise_error = nil
      actor
    end

    it 'writes auth cooldown key when compute raises with HTTP 401 status' do
      actor = make_auth_fail_actor
      err = StandardError.new('Unauthorized')
      err.define_singleton_method(:status_code) { 401 }
      actor.raise_error = err
      actor.should_raise = true

      actor.tick

      expect(cache_store).to have_key(cooldown_key)
    end

    it 'writes auth cooldown key when compute raises with HTTP 403 status' do
      actor = make_auth_fail_actor
      err = StandardError.new('Forbidden')
      err.define_singleton_method(:http_status) { 403 }
      actor.raise_error = err
      actor.should_raise = true

      actor.tick

      expect(cache_store).to have_key(cooldown_key)
    end

    it 'writes auth cooldown key when compute raises with unauthorized message' do
      actor = make_auth_fail_actor
      actor.raise_error = StandardError.new('invalid_api_key: bad credentials')
      actor.should_raise = true

      actor.tick

      expect(cache_store).to have_key(cooldown_key)
    end

    it 'skips compute_lanes_for_scope when cooldown key is present' do
      actor = make_auth_fail_actor
      actor.should_raise = false
      cache_store[cooldown_key] = 1 # simulate active cooldown

      compute_called = false
      actor.define_singleton_method(:compute_lanes_for_scope) do
        compute_called = true
        []
      end

      actor.tick
      expect(compute_called).to be false
    end

    it 'calls compute_lanes_for_scope after cooldown TTL expires' do
      actor = make_auth_fail_actor
      actor.should_raise = false
      # Cooldown expired — key absent
      cache_store.delete(cooldown_key)

      compute_called = false
      actor.define_singleton_method(:compute_lanes_for_scope) do
        compute_called = true
        []
      end

      actor.tick
      expect(compute_called).to be true
    end

    it 'does NOT write cooldown key for non-auth errors' do
      actor = make_auth_fail_actor
      actor.raise_error = StandardError.new('connection timeout: net unreachable')
      actor.should_raise = true

      actor.tick

      expect(cache_store).not_to have_key(cooldown_key)
    end
  end

  describe Legion::Extensions::Llm::Inventory::ScopedRefresher::LegacyCoordinatorAdapter do
    include SsotRegistryHelpers

    inventory = Legion::Extensions::Llm::Inventory
    errors = inventory::Errors

    let(:fake_inventory) do
      Class.new do
        attr_reader :lanes

        def initialize
          @lanes = {}
        end

        def write_lane(lane:, **)
          @lanes[lane[:id]] = lane
          lane
        end

        def delete_lane(id:, **)
          @lanes.delete(id)
          :deleted
        end

        def lanes_for(provider:, instance:, **)
          @lanes.values.select { |l| l[:provider_family].to_s == provider.to_s && l[:instance_id].to_s == instance.to_s }
        end
      end.new
    end

    let(:key) { instance_key(family: 'vllm', instance: 'h200') }
    let(:adapter) { described_class.new(provider_family: :vllm) }

    before do
      inventory::Registry.reset!
      stub_const('Legion::LLM::Inventory', fake_inventory)
    end

    def activate_chat
      claim_and_activate(key: key, callable: fake_callable, coordinator: probe_coordinator(key))
      Legion::Extensions::Llm::Inventory::Registry.snapshot
    end

    it 'projects an available instance into an exact five-field legacy lane and round-trips' do
      allow(Legion::Extensions::Llm::Taxonomies).to receive(:lane_type_for).and_call_original

      result = adapter.sync_snapshot(snapshot: activate_chat, instance_key: key, mutation_reason: :activated)
      expect(result).to eq(:applied)
      expect(Legion::Extensions::Llm::Taxonomies).to have_received(:lane_type_for).with(operation: :chat)

      legacy_id = 'local:vllm:h200:inference:gemma4'
      expect(fake_inventory.lanes).to have_key(legacy_id)
      lane = fake_inventory.lanes[legacy_id]
      expect(lane[:id]).to eq(legacy_id)
      expect(lane[:provider_instance]).to eq('h200')
      expect(lane[:enabled]).to be(true)
      expect(lane[:capabilities]).to include(:completion)
      expect(lane[:metadata]).to include(ssot_v3_compatibility_projection: true)
      round_trip = fake_inventory.lanes_for(provider: :vllm, instance: 'h200', type: :inference, model: 'gemma4')
      expect(round_trip.map { |l| l[:id] }).to eq([legacy_id])
    end

    it 'deletes the old projection when the instance is removed (desired set empty)' do
      token = claim_and_activate(key: key, callable: fake_callable, coordinator: probe_coordinator(key))
      adapter.sync_snapshot(snapshot: inventory::Registry.snapshot, instance_key: key, mutation_reason: :activated)
      expect(fake_inventory.lanes).not_to be_empty

      inventory::Registry.remove_instance(instance_key: key, publisher_token: token)
      adapter.sync_snapshot(snapshot: inventory::Registry.snapshot, instance_key: key, mutation_reason: :removed)
      expect(fake_inventory.lanes).to be_empty
    end

    it 'deletes the old projection when the instance becomes unavailable' do
      token = claim_and_activate(key: key, callable: fake_callable, coordinator: probe_coordinator(key))
      adapter.sync_snapshot(snapshot: inventory::Registry.snapshot, instance_key: key, mutation_reason: :activated)
      inventory::Registry.dispatch_instance_unavailable(instance_key: key, publisher_token_id: token.publisher_token_id, reason: 'down')
      adapter.sync_snapshot(snapshot: inventory::Registry.snapshot, instance_key: key, mutation_reason: :instance_unavailable)
      expect(fake_inventory.lanes).to be_empty
    end

    it 'fails closed and omits an ambiguous group that collapses multiple offerings' do
      token = inventory::Registry.claim_instance(instance_key: key, callable: fake_callable, probe_request_handle: probe_coordinator(key))
      probe = inventory::Registry.readiness_probe_started(instance_key: key, publisher_token: token)
      two = drafts(native: 'a', model: 'gemma4') + drafts(native: 'b', model: 'gemma4')
      inventory::Registry.activate_instance_snapshot(publisher_token: token, instance_key: key, offerings: two, sequence: 0, probe_token: probe)
      adapter.sync_snapshot(snapshot: inventory::Registry.snapshot, instance_key: key, mutation_reason: :activated)
      expect(fake_inventory.lanes).to be_empty
    end

    it 'returns :not_loaded when Legion::LLM::Inventory is absent' do
      hide_const('Legion::LLM::Inventory')
      expect(adapter.sync_snapshot(snapshot: activate_chat, instance_key: key, mutation_reason: :activated)).to eq(:not_loaded)
    end

    it 'rejects a different provider family, an invalid snapshot, and an unknown reason' do
      snapshot = activate_chat
      other = instance_key(family: 'openai', instance: 'h200')
      expect { adapter.sync_snapshot(snapshot: snapshot, instance_key: other, mutation_reason: :activated) }
        .to raise_error(errors::ValidationError)
      expect { adapter.sync_snapshot(snapshot: {}, instance_key: key, mutation_reason: :activated) }
        .to raise_error(errors::ValidationError)
      expect { adapter.sync_snapshot(snapshot: snapshot, instance_key: key, mutation_reason: :made_up) }
        .to raise_error(errors::ValidationError)
    end

    it 'returns :failed and preserves the prior tracked set when a write raises' do
      snapshot = activate_chat
      allow(fake_inventory).to receive(:write_lane).and_raise(StandardError, 'coordinator down')
      expect(adapter.sync_snapshot(snapshot: snapshot, instance_key: key, mutation_reason: :activated)).to eq(:failed)
    end

    it 'never lets an old five-part id be accepted as a canonical lane:v1: identity' do
      offering_id = inventory::Identity.offering_id(instance_key: key, provider_native_key: 'gemma4')
      expect do
        inventory::Identity.validate_lane_id!(
          value: 'local:vllm:h200:inference:gemma4', instance_key: key,
          operation: :chat, model: 'gemma4', offering_id: offering_id
        )
      end.to raise_error(errors::ValidationError)
    end

    it 'leaves the new Registry unchanged when the legacy projection runs' do
      snapshot = activate_chat
      generation = inventory::Registry.snapshot.generation
      adapter.sync_snapshot(snapshot: snapshot, instance_key: key, mutation_reason: :activated)
      expect(inventory::Registry.snapshot.generation).to eq(generation)
    end
  end
end
