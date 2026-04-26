# frozen_string_literal: true

require 'lex_llm'

RSpec.describe LexLLM do
  it 'bridges the new LexLLM require path to the current RubyLLM namespace' do
    expect(described_class).to equal(RubyLLM)
    expect(described_class::Routing::ModelOffering).to equal(RubyLLM::Routing::ModelOffering)
  end
end
