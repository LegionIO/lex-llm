# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/capabilities'

RSpec.describe Legion::Extensions::Llm::Capabilities do
  describe '.normalize' do
    it 'normalizes :function_calling to :tools' do
      expect(described_class.normalize([:function_calling])).to include(:tools)
    end

    it 'normalizes :tool_use to :tools' do
      expect(described_class.normalize([:tool_use])).to include(:tools)
    end

    it 'passes through unknown capabilities unchanged' do
      expect(described_class.normalize([:vision])).to include(:vision)
    end

    it 'returns frozen array' do
      expect(described_class.normalize([:tools])).to be_frozen
    end

    it 'handles nil/empty input gracefully' do
      expect(described_class.normalize(nil)).to eq([])
      expect(described_class.normalize([])).to eq([])
    end
  end

  describe '.include_all?' do
    it 'returns true when required caps are a subset of available' do
      expect(described_class.include_all?(%i[tools vision], [:tools])).to be true
    end

    it 'returns false when a required cap is missing' do
      expect(described_class.include_all?([:vision], [:tools])).to be false
    end

    it 'matches :function_calling against :tools via alias (PR #152 I1)' do
      expect(described_class.include_all?([:function_calling], [:tools])).to be true
    end
  end

  describe '.merge' do
    it 'merges and deduplicates multiple capability sets' do
      result = described_class.merge([:tools], %i[vision tools])
      expect(result.count(:tools)).to eq(1)
    end
  end
end
