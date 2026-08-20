# frozen_string_literal: true

require 'spec_helper'
require_relative '../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::ToolDefinition do
  let(:type_class) { described_class }
  let(:auto_generated_members) { [] }
  let(:type_source) do
    {
      name: 'get_weather',
      description: 'Get the weather',
      parameters: { type: 'object', properties: { location: { type: 'string' } } },
      source: { type: :registry, tool_class: 'WeatherTool' },
      metadata: { origin: 'client' }
    }
  end

  it_behaves_like 'a canonical type'

  describe 'O03a — no input_schema alias' do
    it 'does not translate input_schema (it folds into metadata)' do
      td = described_class.from_hash(name: 'x', input_schema: { type: 'object', properties: {} })
      expect(td.parameters).to eq(type: 'object', properties: {})
      expect(td.metadata).to eq(input_schema: { type: 'object', properties: {} })
    end
  end

  describe 'L3 — no coercion of non-Hash input' do
    it 'raises on non-Hash from_hash input (the {} fabrication is deleted)' do
      expect { described_class.from_hash(nil) }
        .to raise_error(ArgumentError, /expected Hash, got NilClass/)
      expect { described_class.from_hash('raw') }
        .to raise_error(ArgumentError, /expected Hash, got String/)
    end
  end

  describe 'schema normalization (frozen inference rules)' do
    it 'defaults missing/empty parameters to an empty object schema' do
      expect(described_class.build(name: 'x').parameters).to eq(type: 'object', properties: {})
    end

    it 'wraps bare property maps in an object schema' do
      td = described_class.build(name: 'x', parameters: { a: { type: 'string' } })
      expect(td.parameters).to eq(type: 'object', properties: { a: { type: 'string' } })
    end

    it 'keeps explicit type and composite schemas as-is' do
      expect(described_class.build(name: 'x', parameters: { type: 'string' }).parameters)
        .to eq(type: 'string')
      expect(described_class.build(name: 'x', parameters: { oneOf: [] }).parameters)
        .to eq(oneOf: [])
    end
  end

  describe 'name sanitization (cross-wire safety)' do
    it 'sanitizes dots, strips unsafe chars, caps length' do
      expect(described_class.build(name: 'get.weather').name).to eq('get_weather')
      expect(described_class.sanitize_tool_name('a' * 80)).to eq('a' * 64)
      expect(described_class.sanitize_tool_name('')).to eq('tool')
    end
  end

  it 'builds from keyword args with defaults' do
    td = described_class.build(name: 'x')
    expect(td.description).to eq('')
    expect(td.source).to eq(type: :builtin)
  end
end
