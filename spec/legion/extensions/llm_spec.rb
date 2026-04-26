# frozen_string_literal: true

require 'lex_llm'

RSpec.describe Legion::Extensions::Llm do
  it 'exposes the Legion-native extension namespace for autoloading' do
    expect(described_class::Types::ModelOffering).to equal(RubyLLM::Routing::ModelOffering)
    expect(described_class::Routing::LaneKey).to equal(RubyLLM::Routing::LaneKey)
  end

  it 'provides complete default fleet settings' do
    defaults = described_class.default_settings

    expect(defaults.dig(:fleet, :scheduler)).to eq(:basic_get)
    expect(defaults.dig(:fleet, :queue_expires_ms)).to eq(60_000)
    expect(defaults.dig(:fleet, :endpoint, :accept_when)).to eq([])
  end
end
