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
end
