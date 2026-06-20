# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Inventory::Capabilities do
  describe '.normalize' do
    it 'returns symbols for raw capability names' do
      expect(described_class.normalize(%i[tools streaming])).to contain_exactly(:tools, :streaming)
    end

    it 'collapses provider aliases into the canonical vocabulary' do
      expect(described_class.normalize([:function_calling])).to include(:tools)
      expect(described_class.normalize([:tool_use])).to include(:tools)
      expect(described_class.normalize([:stream])).to include(:streaming)
    end

    it 'returns an empty array for nil/empty input' do
      expect(described_class.normalize(nil)).to eq([])
      expect(described_class.normalize([])).to eq([])
    end

    it 'is the same vocabulary as Legion::Extensions::Llm::Capabilities' do
      expect(described_class::ALIASES).to equal(Legion::Extensions::Llm::Capabilities::ALIASES)
    end
  end

  describe '.merge' do
    it 'unions multiple capability sets' do
      result = described_class.merge([:tools], %i[streaming tools])
      expect(result).to contain_exactly(:tools, :streaming)
    end
  end

  describe '.include_all?' do
    it 'returns true when required is a subset of available' do
      expect(described_class.include_all?(%i[tools streaming], [:tools])).to be(true)
    end

    it 'returns false when required is missing from available' do
      expect(described_class.include_all?([:streaming], [:tools])).to be(false)
    end
  end
end
