# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/routing/records'

RSpec.describe Legion::Extensions::Llm::Routing::Records do
  inventory = Legion::Extensions::Llm::Inventory
  routing = Legion::Extensions::Llm::Routing
  errors = inventory::Errors
  identity = inventory::Identity

  let(:callable_class) do
    Class.new do
      def disconnect; end
    end
  end
  let(:callable_handle) { inventory::CallableHandle.new(handle_id: 'call:v1:x', callable: callable_class.new) }
  let(:instance_key) { identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'h200') }
  let(:offering_id) { identity.offering_id(instance_key: instance_key, provider_native_key: 'gemma4') }
  let(:lane_id) do
    identity.lane_id(instance_key: instance_key, operation: :chat, model: 'gemma4', offering_id: offering_id)
  end

  describe routing::AttemptTargetKey do
    it 'treats the same model on two instances as distinct keys' do
      a = described_class.new(provider_family: 'vllm', instance_id: 'h200', model: 'gemma4')
      b = described_class.new(provider_family: 'vllm', instance_id: 'helios1', model: 'gemma4')
      expect(a).not_to eq(b)
    end

    it 'is value-equal for equal normalized fields and hashes equally' do
      a = described_class.new(provider_family: 'vllm', instance_id: 'h200', model: 'gemma4')
      b = described_class.new(provider_family: :vllm, instance_id: '  h200 ', model: 'gemma4')
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it 'contains only provider_family, instance_id, and model' do
      key = described_class.new(provider_family: 'vllm', instance_id: 'h200', model: 'gemma4')
      expect(key.to_h.keys).to contain_exactly(:provider_family, :instance_id, :model)
    end
  end

  describe routing::QuotaDomainKey do
    it 'never compares equal across provider families' do
      a = described_class.new(provider_family: 'vllm', opaque_id: 'q1')
      b = described_class.new(provider_family: 'openai', opaque_id: 'q1')
      expect(a).not_to eq(b)
    end
  end

  describe routing::Exclusion do
    it 'requires the target class to match the target_kind' do
      expect do
        described_class.new(target_kind: :instance, target: instance_key, reason: 'x', evidence: {}, lifetime: :request)
      end.not_to raise_error
      expect do
        described_class.new(target_kind: :instance, target: 'nope', reason: 'x', evidence: {}, lifetime: :request)
      end.to raise_error(errors::ValidationError)
    end

    it 'normalizes a provider target to a canonical Symbol' do
      exclusion = described_class.new(target_kind: :provider, target: 'VLLM', reason: 'x', evidence: {}, lifetime: :request)
      expect(exclusion.target).to eq(:vllm)
    end

    it 'freezes evidence and rejects an invalid lifetime' do
      exclusion = described_class.new(target_kind: :model, target: 'gemma4', reason: 'x', evidence: { a: 1 }, lifetime: :attempt_group)
      expect(exclusion.evidence).to be_frozen
      expect do
        described_class.new(target_kind: :model, target: 'gemma4', reason: 'x', evidence: {}, lifetime: :forever)
      end.to raise_error(errors::ValidationError)
    end
  end

  describe routing::Selection do
    def build_selection(**overrides)
      Legion::Extensions::Llm::Routing::Selection.new(
        inventory_generation: 7, lane_id: lane_id, instance_key: instance_key, offering_id: offering_id,
        provider_family: :vllm, instance_id: 'h200', model: 'gemma4', operation: :chat,
        callable_handle: callable_handle, publisher_token_id: 'ptok:v1:abc', capability_evidence: {},
        context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
        weight_inputs: { tier: 2, provider: 3, instance: 5, model_or_offering: 7 },
        base_weight: 210, preference_ppm: 1_000_000, effective_weight: 210_000_000,
        rendezvous_score: 12_345, **overrides
      )
    end

    it 'builds a valid selection and derives the attempt target key' do
      selection = build_selection
      key = selection.attempt_target_key
      expect(key).to eq(routing::AttemptTargetKey.new(provider_family: :vllm, instance_id: 'h200', model: 'gemma4'))
    end

    it 'requires base_weight to equal the product of weight_inputs' do
      expect { build_selection(base_weight: 211) }.to raise_error(errors::ValidationError)
    end

    it 'requires effective_weight to equal base_weight * preference_ppm' do
      expect { build_selection(effective_weight: 1) }.to raise_error(errors::ValidationError)
    end

    it 'bounds preference_ppm to 500_000..1_500_000' do
      expect { build_selection(preference_ppm: 400_000, effective_weight: 210 * 400_000) }
        .to raise_error(errors::ValidationError)
    end

    it 'rejects a lane_id that does not reproduce' do
      expect { build_selection(lane_id: "lane:v1:#{'0' * 64}") }.to raise_error(errors::ValidationError)
    end

    it 'rejects a publisher_token_id without the ptok:v1: prefix' do
      expect { build_selection(publisher_token_id: 'nope') }.to raise_error(errors::ValidationError)
    end

    it 'freezes weight_inputs' do
      expect(build_selection.weight_inputs).to be_frozen
    end
  end

  describe routing::Rejection do
    def build_rejection(**overrides)
      Legion::Extensions::Llm::Routing::Rejection.new(
        kind: :too_early, reason: 'initializing', inventory_generation: 0, candidate_counts: { eligible: 0 }, **overrides
      )
    end

    it 'validates kind and freezes candidate_counts' do
      rejection = build_rejection
      expect(rejection.candidate_counts).to be_frozen
      expect { build_rejection(kind: :made_up) }.to raise_error(errors::ValidationError)
    end

    it 'rejects candidate_counts with non-Symbol keys or negative values' do
      expect { build_rejection(candidate_counts: { 'x' => 1 }) }.to raise_error(errors::ValidationError)
      expect { build_rejection(candidate_counts: { eligible: -1 }) }.to raise_error(errors::ValidationError)
    end

    it 'allows only provider/instance/model/tier explicit pins' do
      expect { build_rejection(explicit_pins: { provider: 'vllm', tier: 'local' }) }.not_to raise_error
      expect { build_rejection(explicit_pins: { secret: 'x' }) }.to raise_error(errors::ValidationError)
    end

    it 'bounds http_status to 100..599' do
      expect { build_rejection(http_status: 700) }.to raise_error(errors::ValidationError)
      expect(build_rejection(http_status: 503).http_status).to eq(503)
    end
  end

  describe routing::BodyModelHintDecision do
    it 'allows only honored to carry a model_constraint' do
      expect do
        described_class.new(
          requested_model: 'gemma4', disposition: :honored, model_constraint: 'gemma4', settings_generation: 1
        )
      end.not_to raise_error
      expect do
        described_class.new(
          requested_model: 'gemma4', disposition: :auto, model_constraint: 'gemma4', settings_generation: 1
        )
      end.to raise_error(errors::ValidationError)
    end

    it 'requires absent to carry a nil requested_model' do
      expect do
        described_class.new(requested_model: 'gemma4', disposition: :absent, settings_generation: 1)
      end.to raise_error(errors::ValidationError)
      expect do
        described_class.new(requested_model: nil, disposition: :absent, settings_generation: 1)
      end.not_to raise_error
    end
  end
end
