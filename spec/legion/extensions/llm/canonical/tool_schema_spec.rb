# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::ToolSchema do
  let(:full_schema) { { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] } }
  let(:canonical_tool) do
    Legion::Extensions::Llm::Canonical::ToolDefinition.build(
      name: 'get_weather', description: 'Weather lookup', parameters: full_schema
    )
  end

  describe '.extract' do
    it 'extracts from a Canonical::ToolDefinition' do
      result = described_class.extract(canonical_tool)
      expect(result[:type]).to eq('object')
      expect(result[:properties]).to eq(city: { type: 'string' })
    end

    it 'extracts from a Hash with :parameters' do
      result = described_class.extract({ parameters: full_schema })
      expect(result[:type]).to eq('object')
      expect(result[:properties]).to eq(city: { type: 'string' })
    end

    it 'extracts from a Hash with :input_schema' do
      result = described_class.extract({ input_schema: full_schema })
      expect(result[:type]).to eq('object')
      expect(result[:properties]).to eq(city: { type: 'string' })
    end

    it 'extracts from a Hash with :params_schema' do
      result = described_class.extract({ params_schema: full_schema })
      expect(result[:type]).to eq('object')
      expect(result[:properties]).to eq(city: { type: 'string' })
    end

    it 'extracts from an object responding to params_schema' do
      tool = Struct.new(:params_schema).new(full_schema)
      result = described_class.extract(tool)
      expect(result[:type]).to eq('object')
      expect(result[:properties]).to eq(city: { type: 'string' })
    end

    it 'returns empty object schema for nil' do
      expect(described_class.extract(nil)).to eq(type: 'object', properties: {})
    end

    it 'returns empty object schema for empty hash' do
      expect(described_class.extract({})).to eq(type: 'object', properties: {})
    end
  end

  describe '.tool_name' do
    it 'gets name from Canonical::ToolDefinition' do
      expect(described_class.tool_name(canonical_tool)).to eq('get_weather')
    end

    it 'gets name from Hash' do
      expect(described_class.tool_name({ name: 'foo' })).to eq('foo')
    end
  end

  describe '.tool_description' do
    it 'gets description from Canonical::ToolDefinition' do
      expect(described_class.tool_description(canonical_tool)).to eq('Weather lookup')
    end

    it 'gets description from Hash' do
      expect(described_class.tool_description({ description: 'bar' })).to eq('bar')
    end
  end

  describe 'ToolDefinition compatibility readers' do
    it 'params_schema returns normalized parameters' do
      expect(canonical_tool.params_schema).to eq(full_schema)
    end

    it 'input_schema aliases params_schema' do
      expect(canonical_tool.input_schema).to eq(canonical_tool.params_schema)
    end
  end
end
