# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/evidence'

RSpec.describe Legion::Extensions::Llm::Inventory::Evidence do
  let(:errors) { Legion::Extensions::Llm::Inventory::Errors }
  let(:operation_evidence) { Legion::Extensions::Llm::Inventory::OperationEvidence }
  let(:capability_evidence) { Legion::Extensions::Llm::Inventory::CapabilityEvidence }
  let(:value_evidence) { Legion::Extensions::Llm::Inventory::ValueEvidence }

  describe 'OperationEvidence' do
    it 'stores a canonical operation and exposes exact predicates' do
      ev = operation_evidence.new(operation: :chat, status: :supported, source: :provider_implementation)
      expect(ev.operation).to eq(:chat)
      expect(ev).to be_supported
      expect(ev).not_to be_unknown
    end

    it 'keeps stream_chat as the operation and never canonicalizes to capability streaming' do
      ev = operation_evidence.new(operation: :stream_chat, status: :supported, source: :provider_catalog)
      expect(ev.operation).to eq(:stream_chat)
      expect(ev.operation).not_to eq(:streaming)
    end

    it 'rejects an operation alias when allow_aliases is false (registry path)' do
      expect { operation_evidence.new(operation: :stream, status: :supported, source: :provider_catalog) }
        .to raise_error(errors::ValidationError)
    end

    it 'rejects an unknown operation' do
      expect { operation_evidence.new(operation: :nonsense, status: :unknown, source: :absent) }
        .to raise_error(errors::ValidationError)
    end

    it 'rejects a status outside supported/unsupported/unknown' do
      expect { operation_evidence.new(operation: :chat, status: :maybe, source: :provider_implementation) }
        .to raise_error(errors::ValidationError)
    end

    it 'rejects a source outside EVIDENCE_SOURCES' do
      expect { operation_evidence.new(operation: :chat, status: :supported, source: :made_up) }
        .to raise_error(errors::ValidationError)
    end

    it 'requires unknown status for an unknown-only source' do
      expect { operation_evidence.new(operation: :chat, status: :supported, source: :default_false) }
        .to raise_error(errors::ValidationError)
      expect { operation_evidence.new(operation: :chat, status: :unknown, source: :default_false) }
        .not_to raise_error
    end

    it 'freezes copied metadata' do
      ev = operation_evidence.new(
        operation: :chat, status: :supported, source: :provider_implementation, metadata: { note: +'x' }
      )
      expect(ev.metadata).to be_frozen
      expect(ev.metadata[:note]).to be_frozen
    end

    it 'duplicates and freezes observed_at but rejects a non-Time' do
      now = Time.now
      ev = operation_evidence.new(operation: :chat, status: :supported, source: :probe, observed_at: now)
      expect(ev.observed_at).to be_frozen
      expect(ev.observed_at).not_to equal(now)
      expect { operation_evidence.new(operation: :chat, status: :supported, source: :probe, observed_at: 5) }
        .to raise_error(errors::ValidationError)
    end
  end

  describe 'CapabilityEvidence' do
    it 'canonicalizes a capability alias' do
      ev = capability_evidence.new(capability: :tool_use, status: :supported, source: :provider_implementation)
      expect(ev.capability).to eq(:tools)
    end

    it 'canonicalizes the stream_chat capability alias to streaming (distinct from the operation)' do
      ev = capability_evidence.new(capability: :stream_chat, status: :supported, source: :provider_catalog)
      expect(ev.capability).to eq(:streaming)
    end

    it 'rejects a non-canonical capability' do
      expect { capability_evidence.new(capability: :telepathy, status: :unknown, source: :absent) }
        .to raise_error(errors::ValidationError)
    end

    it 'requires unknown status for guessed/default_false/failed_probe sources' do
      %i[guessed default_false failed_probe inconclusive_probe].each do |source|
        expect { capability_evidence.new(capability: :vision, status: :unsupported, source: source) }
          .to raise_error(errors::ValidationError)
        expect { capability_evidence.new(capability: :vision, status: :unknown, source: source) }
          .not_to raise_error
      end
    end
  end

  describe 'ValueEvidence' do
    it 'requires a non-nil value when known and copies/freezes it' do
      ev = value_evidence.new(status: :known, value: 128_000, source: :model_metadata)
      expect(ev).to be_known
      expect(ev.value).to eq(128_000)
    end

    it 'freezes a known collection value' do
      ev = value_evidence.new(status: :known, value: [512, 1024], source: :provider_catalog)
      expect(ev.value).to be_frozen
    end

    it 'rejects a known status with a nil value' do
      expect { value_evidence.new(status: :known, value: nil, source: :model_metadata) }
        .to raise_error(errors::ValidationError)
    end

    it 'requires nil value when unknown' do
      expect { value_evidence.new(status: :unknown, value: 5, source: :absent) }
        .to raise_error(errors::ValidationError)
      expect(value_evidence.new(status: :unknown, source: :absent)).to be_unknown
    end

    it 'enforces the unknown-only source rule' do
      expect { value_evidence.new(status: :known, value: 10, source: :guessed) }
        .to raise_error(errors::ValidationError)
    end
  end
end
