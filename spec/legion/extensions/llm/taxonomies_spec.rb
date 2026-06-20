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
end
