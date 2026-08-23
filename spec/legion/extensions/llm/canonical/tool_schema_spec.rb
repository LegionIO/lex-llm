# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::ToolSchema do
  let(:tool_definition) do
    Legion::Extensions::Llm::Canonical::ToolDefinition.build(
      name: 'get_weather',
      description: 'Get the weather',
      parameters: { type: 'object', properties: { location: { type: 'string' } } }
    )
  end

  it 'extracts the normalized schema from a ToolDefinition' do
    expect(described_class.extract(tool_definition)).to eq(
      type: 'object', properties: { location: { type: 'string' } }
    )
  end

  it 'returns the tool name and description' do
    expect(described_class.tool_name(tool_definition)).to eq('get_weather')
    expect(described_class.tool_description(tool_definition)).to eq('Get the weather')
  end

  describe '04 §6 — ToolDefinition ONLY (dual-shape accessors deleted)' do
    it 'raises on a raw Hash' do
      expect { described_class.extract({ name: 'x' }) }
        .to raise_error(ArgumentError, /expected Canonical::ToolDefinition, got Hash/)
      expect { described_class.tool_name({ name: 'x' }) }
        .to raise_error(ArgumentError, /expected Canonical::ToolDefinition, got Hash/)
      expect { described_class.tool_description({ name: 'x' }) }
        .to raise_error(ArgumentError, /expected Canonical::ToolDefinition, got Hash/)
    end

    it 'raises on nil and other wrong classes' do
      expect { described_class.extract(nil) }
        .to raise_error(ArgumentError, /expected Canonical::ToolDefinition, got NilClass/)
      expect { described_class.tool_name('str') }
        .to raise_error(ArgumentError, /expected Canonical::ToolDefinition, got String/)
    end
  end
end
