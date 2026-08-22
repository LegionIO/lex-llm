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

  describe 'M5 — the name is authoritative (no rewrite, no fabrication)' do
    it 'preserves the client/registry name verbatim (dialect rules live at the provider edge)' do
      expect(described_class.build(name: 'get.weather').name).to eq('get.weather')
      expect(described_class.build(name: 'a' * 80).name).to eq('a' * 80)
      expect(described_class).not_to respond_to(:sanitize_tool_name)
    end

    it 'raises on a missing or empty name (the "tool" fabrication is deleted)' do
      expect { described_class.build(name: nil) }
        .to raise_error(ArgumentError, /name must be a non-empty String/)
      expect { described_class.build(name: '') }
        .to raise_error(ArgumentError, /name must be a non-empty String/)
      expect { described_class.from_hash({}) }
        .to raise_error(ArgumentError, /name must be a non-empty String/)
    end

    it 'does not fabricate a source (explicit or absent, never laundered to builtin)' do
      expect(described_class.build(name: 'x').source).to be_nil
      expect(described_class.build(name: 'x', source: { type: :client }).source).to eq(type: :client)
      expect { described_class.build(name: 'x', source: 'client') }
        .to raise_error(ArgumentError, /source expected Hash/)
    end
  end

  it 'builds from keyword args with defaults (empty description, absent source)' do
    td = described_class.build(name: 'x')
    expect(td.description).to eq('')
    expect(td.source).to be_nil
  end
end
