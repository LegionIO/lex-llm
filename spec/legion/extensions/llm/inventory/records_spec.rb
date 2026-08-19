# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/records'

RSpec.describe Legion::Extensions::Llm::Inventory::Records do
  inventory = Legion::Extensions::Llm::Inventory
  errors = inventory::Errors
  identity = inventory::Identity
  taxonomies = Legion::Extensions::Llm::Taxonomies

  let(:callable_class) do
    Class.new do
      def disconnect; end
    end
  end
  let(:callable_handle) { inventory::CallableHandle.new(handle_id: 'call:v1:test', callable: callable_class.new) }
  let(:instance_key) { identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'h200') }
  let(:offering_id) { identity.offering_id(instance_key: instance_key, provider_native_key: 'gemma4') }
  let(:lane_id) do
    identity.lane_id(instance_key: instance_key, operation: :chat, model: 'gemma4', offering_id: offering_id)
  end

  def value_unknown
    Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
  end

  def full_operation_evidence(supported: [])
    Legion::Extensions::Llm::Taxonomies::OPERATIONS.to_h do |op|
      status, source = supported.include?(op) ? %i[supported provider_implementation] : %i[unknown absent]
      [op, Legion::Extensions::Llm::Inventory::OperationEvidence.new(operation: op, status: status, source: source)]
    end
  end

  def scalar_evidence_kwargs
    {
      context_evidence: value_unknown, max_output_evidence: value_unknown,
      embedding_dimensions_evidence: value_unknown, model_revision_evidence: value_unknown,
      tokenizer_evidence: value_unknown
    }
  end

  def build_draft(**overrides)
    Legion::Extensions::Llm::Inventory::OfferingDraft.new(
      provider_native_key: 'gemma4', model: 'gemma4', tier: :local,
      operation_evidence: full_operation_evidence(supported: %i[chat]),
      publication_source: :provider_catalog, **scalar_evidence_kwargs, **overrides
    )
  end

  def build_offering_record(**overrides)
    Legion::Extensions::Llm::Inventory::OfferingRecord.new(
      offering_id: offering_id, provider_native_key: 'gemma4', instance_key: instance_key, model: 'gemma4',
      tier: :local, operation_evidence: full_operation_evidence(supported: %i[chat]), capability_evidence: {},
      quota_domains: {}, metadata: {}, callable_handle: callable_handle, publication_source: :provider_catalog,
      **scalar_evidence_kwargs, **overrides
    )
  end

  def build_lane(**overrides)
    Legion::Extensions::Llm::Inventory::LaneRecord.new(
      lane_id: lane_id, offering_id: offering_id, instance_key: instance_key, provider_family: :vllm,
      instance_id: 'h200', model: 'gemma4', tier: :local, operation: :chat, capability_evidence: {},
      quota_domain: nil, metadata: {}, callable_handle: callable_handle, publication_source: :provider_catalog,
      **scalar_evidence_kwargs, **overrides
    )
  end

  shared_examples 'an atomic immutable weight pair' do
    it 'defaults both omitted fields to the frozen identity pair' do
      record = build_record
      expect(record.weight_inputs).to eq(tier: 100, provider: 100, instance: 100, model_or_offering: 100)
      expect(record.weight_inputs).to be_frozen
      expect(record.base_weight).to eq(100_000_000)
    end

    it 'requires the pair atomically and rejects every invalid shape' do
      valid = { tier: 150, provider: 100, instance: 115, model_or_offering: 100 }
      expect { build_record(weight_inputs: valid) }.to raise_error(errors::ValidationError)
      expect { build_record(base_weight: 172_500_000) }.to raise_error(errors::ValidationError)
      expect { build_record(weight_inputs: [], base_weight: 1) }.to raise_error(errors::ValidationError)
      expect { build_record(weight_inputs: valid.merge('tier' => 150).except(:tier), base_weight: 172_500_000) }
        .to raise_error(errors::ValidationError)
      expect { build_record(weight_inputs: valid.merge(provider: -1), base_weight: -172_500) }
        .to raise_error(errors::ValidationError)
      expect { build_record(weight_inputs: valid.merge(provider: 100.0), base_weight: 172_500_000) }
        .to raise_error(errors::ValidationError)
      expect { build_record(weight_inputs: valid, base_weight: 172_500_000.0) }
        .to raise_error(errors::ValidationError)
      expect { build_record(weight_inputs: valid, base_weight: 1) }.to raise_error(errors::ValidationError)
    end

    it 'defensively freezes a supplied valid pair' do
      source = { tier: 150, provider: 100, instance: 115, model_or_offering: 100 }
      record = build_record(weight_inputs: source, base_weight: 172_500_000)
      source[:tier] = 1

      expect(record.weight_inputs).to eq(tier: 150, provider: 100, instance: 115, model_or_offering: 100)
      expect(record.weight_inputs).to be_frozen
      expect(record.base_weight).to eq(172_500_000)
    end
  end

  describe inventory::OfferingDraft do
    def build_record(**overrides)
      build_draft(**overrides)
    end

    include_examples 'an atomic immutable weight pair'

    it 'builds a valid frozen draft' do
      draft = build_draft
      expect(draft).to be_frozen
      expect(draft.model).to eq('gemma4')
      expect(draft.operation_evidence).to be_frozen
    end

    it 'rejects an unknown kwarg' do
      expect { build_draft(bogus: 1) }.to raise_error(ArgumentError)
    end

    it 'requires operation_evidence to contain every canonical operation exactly' do
      incomplete = full_operation_evidence.except(:moderate)
      expect { build_draft(operation_evidence: incomplete) }.to raise_error(errors::ValidationError)
    end

    it 'rejects an operation_evidence value whose operation mismatches its key' do
      mismatched = full_operation_evidence
      mismatched[:chat] = Legion::Extensions::Llm::Inventory::OperationEvidence.new(
        operation: :embed, status: :supported, source: :provider_implementation
      )
      expect { build_draft(operation_evidence: mismatched) }.to raise_error(errors::ValidationError)
    end

    it 'rejects secret-like metadata keys at any nesting level' do
      expect { build_draft(metadata: { api_key: 'x' }) }.to raise_error(errors::ValidationError)
      expect { build_draft(metadata: { nested: [{ authorization_header: 'x' }] }) }
        .to raise_error(errors::ValidationError)
    end

    it 'rejects a known context value that is not a positive Integer' do
      bad = Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: 0, source: :model_metadata)
      expect { build_draft(context_evidence: bad) }.to raise_error(errors::ValidationError)
    end

    it 'rejects unsorted embedding dimensions' do
      bad = Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :known, value: [1024, 512], source: :provider_catalog
      )
      expect { build_draft(embedding_dimensions_evidence: bad) }.to raise_error(errors::ValidationError)
    end

    it 'freezes copied metadata deeply' do
      draft = build_draft(metadata: { a: { b: [1] } })
      expect(draft.metadata[:a][:b]).to be_frozen
    end

    it 'normalizes quota_domain keys to canonical operations' do
      draft = build_draft(quota_domains: { 'chat' => 'domain-a' })
      expect(draft.quota_domains).to eq(chat: 'domain-a')
    end
  end

  describe inventory::OfferingRecord do
    def build_record(**overrides)
      build_offering_record(**overrides)
    end

    include_examples 'an atomic immutable weight pair'

    it 'validates offering_id reproduction and exposes operation views' do
      record = build_offering_record
      expect(record.supported_operations).to eq(%i[chat])
      expect(record.operation_status(operation: :chat)).to eq(:supported)
      expect(record.operation_status(operation: :embed)).to eq(:unknown)
      expect(record.capability_status(capability: :vision)).to eq(:unknown)
      expect(record.unknown_operations).to include(:embed)
    end

    it 'rejects an offering_id that does not reproduce' do
      expect { build_offering_record(offering_id: "off:v1:#{'0' * 64}") }.to raise_error(errors::ValidationError)
    end

    it 'rejects a non-InstanceKey and a non-CallableHandle' do
      expect { build_offering_record(instance_key: :vllm) }.to raise_error(errors::ValidationError)
      expect { build_offering_record(callable_handle: Object.new) }.to raise_error(errors::ValidationError)
    end

    it 'returns the quota domain for an operation' do
      record = build_offering_record(quota_domains: { chat: 'domain-a' })
      expect(record.quota_domain(operation: :chat)).to eq('domain-a')
      expect(record.quota_domain(operation: :embed)).to be_nil
    end
  end

  describe inventory::LaneRecord do
    def build_record(**overrides)
      build_lane(**overrides)
    end

    include_examples 'an atomic immutable weight pair'

    it 'builds a valid lane whose id reproduces' do
      expect(build_lane.lane_id).to eq(lane_id)
    end

    it 'rejects provider_family/instance_id not equal to instance_key' do
      expect { build_lane(instance_id: 'helios1') }.to raise_error(errors::ValidationError)
    end

    it 'rejects a lane_id that does not reproduce' do
      expect { build_lane(lane_id: "lane:v1:#{'0' * 64}") }.to raise_error(errors::ValidationError)
    end
  end

  describe inventory::AvailabilityFact do
    def build_fact(**overrides)
      Legion::Extensions::Llm::Inventory::AvailabilityFact.new(
        state: :available, availability_revision: 1, source: :startup_readiness, reason: 'activated', observed_at: nil,
        **overrides
      )
    end

    it 'accepts an available fact with nil unavailable_revision' do
      expect(build_fact.state).to eq(:available)
    end

    it 'requires unavailable_revision to equal availability_revision when unavailable' do
      expect { build_fact(state: :unavailable, availability_revision: 3, source: :dispatch, unavailable_revision: 2) }
        .to raise_error(errors::ValidationError)
      expect do
        build_fact(state: :unavailable, availability_revision: 3, source: :dispatch, unavailable_revision: 3)
      end.not_to raise_error
    end

    it 'rejects a non-unavailable state that carries an unavailable_revision' do
      expect { build_fact(unavailable_revision: 1) }.to raise_error(errors::ValidationError)
    end

    it 'requires both probe timestamps for a non-nil outcome and forbids completion before start' do
      now = Time.now
      expect { build_fact(last_probe_outcome: :success) }.to raise_error(errors::ValidationError)
      expect do
        build_fact(last_probe_outcome: :success, last_probe_started_at: now + 5, last_probe_completed_at: now)
      end.to raise_error(errors::ValidationError)
    end

    it 'has no cooldown/half-open/latency fields' do
      expect(build_fact.to_h.keys).to contain_exactly(
        :state, :availability_revision, :source, :reason, :observed_at,
        :last_probe_started_at, :last_probe_completed_at, :last_probe_outcome, :unavailable_revision
      )
    end
  end

  describe inventory::ReadinessResult do
    it 'exposes ready? and rejects a non-boolean ready' do
      result = Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: true, reason: 'ok')
      expect(result).to be_ready
      expect { Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: 'yes', reason: 'ok') }
        .to raise_error(errors::ValidationError)
    end

    it 'rejects secret metadata' do
      expect { Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: true, reason: 'ok', metadata: { secret: 'x' }) }
        .to raise_error(errors::ValidationError)
    end
  end

  describe inventory::InstanceRecord do
    def build_instance(**overrides)
      Legion::Extensions::Llm::Inventory::InstanceRecord.new(
        instance_key: instance_key, callable_handle: callable_handle,
        availability: Legion::Extensions::Llm::Inventory::AvailabilityFact.new(
          state: :available, availability_revision: 1, source: :startup_readiness, reason: 'activated', observed_at: nil
        ),
        offerings_by_id: { offering_id => build_offering_record },
        publisher_id: 'pub:v1:x', publisher_token_id: 'ptok:v1:y', published_sequence: 1, published_at: Time.now,
        **overrides
      )
    end

    it 'builds an available instance with a complete offerings map' do
      expect(build_instance.offerings_by_id).to be_frozen
    end

    it 'rejects an initializing availability' do
      initializing = Legion::Extensions::Llm::Inventory::AvailabilityFact.new(
        state: :initializing, availability_revision: 0, source: :startup_readiness, reason: 'claim', observed_at: nil
      )
      expect { build_instance(availability: initializing) }.to raise_error(errors::ValidationError)
    end

    it 'accepts an explicit empty offerings map' do
      expect(build_instance(offerings_by_id: {}).offerings_by_id).to eq({})
    end
  end

  describe inventory::PublicationStatus do
    it 'accepts initializing with a nil sequence and complete with a sequence' do
      initializing = Legion::Extensions::Llm::Inventory::PublicationStatus.new(
        instance_key: instance_key, state: :initializing, publisher_token_id: 'ptok:v1:x', published_sequence: nil
      )
      expect(initializing.state).to eq(:initializing)
      complete = Legion::Extensions::Llm::Inventory::PublicationStatus.new(
        instance_key: instance_key, state: :complete, publisher_token_id: 'ptok:v1:x', published_sequence: 2
      )
      expect(complete.published_sequence).to eq(2)
    end

    it 'rejects an invalid state' do
      expect do
        Legion::Extensions::Llm::Inventory::PublicationStatus.new(
          instance_key: instance_key, state: :available, publisher_token_id: nil, published_sequence: nil
        )
      end.to raise_error(errors::ValidationError)
    end
  end

  describe inventory::MutationResult do
    it 'accepts applied: true with a normal reason' do
      result = Legion::Extensions::Llm::Inventory::MutationResult.new(
        applied: true, reason: :activated, generation: 3, instance_key: instance_key
      )
      expect(result).to be_applied
    end

    it 'requires a stale/already-removed reason when applied is false' do
      expect do
        Legion::Extensions::Llm::Inventory::MutationResult.new(
          applied: false, reason: :stale_publisher, generation: 3, instance_key: instance_key
        )
      end.not_to raise_error
      expect do
        Legion::Extensions::Llm::Inventory::MutationResult.new(
          applied: false, reason: :activated, generation: 3, instance_key: instance_key
        )
      end.to raise_error(errors::ValidationError)
    end

    it 'rejects a stale reason when applied is true' do
      expect do
        Legion::Extensions::Llm::Inventory::MutationResult.new(
          applied: true, reason: :stale_publisher, generation: 3, instance_key: instance_key
        )
      end.to raise_error(errors::ValidationError)
    end
  end

  it 'exposes taxonomies operations used by the records' do
    expect(taxonomies::OPERATIONS).to include(:chat, :embed)
  end
end
