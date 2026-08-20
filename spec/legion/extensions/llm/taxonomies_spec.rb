# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/taxonomies'

RSpec.describe Legion::Extensions::Llm::Taxonomies do
  it 'TIERS includes :fleet as a first-class tier' do
    expect(described_class::TIERS).to include(:fleet)
  end

  it 'TIERS contains exactly the documented values' do
    expect(described_class::TIERS).to contain_exactly(:direct, :local, :fleet, :cloud, :frontier)
  end

  it 'TYPES contains documented inference types' do
    expect(described_class::TYPES).to include(:inference, :embedding)
  end

  it 'all constants are frozen' do
    expect(described_class::TIERS).to be_frozen
    expect(described_class::TYPES).to be_frozen
    expect(described_class::OPERATIONS).to be_frozen
  end

  it 'removes the legacy enums (0.8.0 rip)' do
    expect(described_class.const_defined?(:CIRCUIT_STATES, false)).to be(false)
    expect(described_class.const_defined?(:HEALTH_KEYS, false)).to be(false)
    expect(described_class.const_defined?(:OPERATION_ALIASES, false)).to be(false)
    expect(described_class.const_defined?(:OPERATION_TO_LANE_TYPE, false)).to be(false)
  end

  describe 'SSOT v3 enums' do
    it 'OPERATIONS contains exactly the nine canonical operations' do
      expect(described_class::OPERATIONS).to eq(
        %i[chat stream_chat embed image transcribe translate speak moderate count_tokens]
      )
    end

    it 'freezes every SSOT enum constant' do
      %i[
        OPERATIONS CAPABILITY_EVIDENCE_STATES OPERATION_EVIDENCE_STATES VALUE_EVIDENCE_STATES
        AVAILABILITY_STATES AVAILABILITY_SOURCES PROBE_OUTCOMES PUBLICATION_STATES CALLABLE_STATES
        MUTATION_REASONS PROVIDER_OUTCOMES REJECTION_KINDS EXCLUSION_TARGET_KINDS EXCLUSION_LIFETIMES
        BODY_MODEL_HINT_DISPOSITIONS EVIDENCE_SOURCES UNKNOWN_ONLY_EVIDENCE_SOURCES
      ].each { |const| expect(described_class.const_get(const)).to be_frozen }
    end

    it 'UNKNOWN_ONLY_EVIDENCE_SOURCES is a subset of EVIDENCE_SOURCES' do
      expect(described_class::EVIDENCE_SOURCES).to include(*described_class::UNKNOWN_ONLY_EVIDENCE_SOURCES)
    end
  end

  describe '.normalize_operation' do
    it 'returns a canonical operation unchanged' do
      expect(described_class.normalize_operation(value: 'chat')).to eq(:chat)
      expect(described_class.normalize_operation(value: :stream_chat)).to eq(:stream_chat)
    end

    it 'rejects every legacy alias — one canonical spelling (06 P5)' do
      %i[stream embedding moderation audio_translation speech].each do |input|
        expect { described_class.normalize_operation(value: input) }
          .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
      end
    end

    it 'raises on unknown, empty, and invalid UTF-8 input' do
      expect { described_class.normalize_operation(value: :nope) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
      expect { described_class.normalize_operation(value: '   ') }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
      expect { described_class.normalize_operation(value: "\xFF".b) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end
end
