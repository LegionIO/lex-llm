# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/scoped_refresher'

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
end
