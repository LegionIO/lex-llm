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

  it 'CIRCUIT_STATES contains three states' do
    expect(described_class::CIRCUIT_STATES).to contain_exactly(:closed, :half_open, :open)
  end

  it 'all constants are frozen' do
    expect(described_class::TIERS).to be_frozen
    expect(described_class::TYPES).to be_frozen
    expect(described_class::CIRCUIT_STATES).to be_frozen
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

    it 'accepts only the documented aliases when allow_aliases is true' do
      {
        stream: :stream_chat, embedding: :embed, moderation: :moderate,
        audio_translation: :translate, speech: :speak
      }.each do |input, canonical|
        expect(described_class.normalize_operation(value: input, allow_aliases: true)).to eq(canonical)
      end
    end

    it 'raises on an alias when allow_aliases is false' do
      expect { described_class.normalize_operation(value: :stream) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
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

  describe '.lane_type_for' do
    let(:mapping) do
      {
        chat: :inference, stream_chat: :inference, embed: :embedding,
        image: :image, transcribe: :audio, translate: :audio, speak: :audio,
        moderate: :inference, count_tokens: :inference
      }
    end

    it 'owns the complete frozen operation-to-lane-type mapping' do
      expect(described_class::OPERATION_TO_LANE_TYPE).to eq(mapping)
      expect(described_class::OPERATION_TO_LANE_TYPE).to be_frozen
      expect(described_class::OPERATION_TO_LANE_TYPE.keys).to match_array(described_class::OPERATIONS)
      expect(described_class::OPERATION_TO_LANE_TYPE.values.uniq)
        .to match_array(described_class::TYPES)
    end

    it 'resolves every canonical operation and rejects unknown operations' do
      mapping.each do |operation, lane_type|
        expect(described_class.lane_type_for(operation: operation)).to eq(lane_type)
      end

      expect { described_class.lane_type_for(operation: :unknown) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end
end
