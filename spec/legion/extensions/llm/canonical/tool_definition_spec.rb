# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Canonical::ToolDefinition do
  describe '.build' do
    it 'creates a tool definition with name and description' do
      tool = described_class.build(name: 'search', description: 'Search the web')

      expect(tool.name).to eq('search')
      expect(tool.description).to eq('Search the web')
      expect(tool.parameters).to eq({})
      expect(tool.source).to eq({ type: :builtin })
    end

    it 'accepts parameters and source' do
      tool = described_class.build(
        name: 'search',
        description: 'Search',
        parameters: { type: 'object', properties: { query: { type: 'string' } } },
        source: { type: :registry }
      )

      expect(tool.parameters).to eq({ type: 'object', properties: { query: { type: 'string' } } })
      expect(tool.source).to eq({ type: :registry })
    end

    it 'sanitizes tool names' do
      tool = described_class.build(name: 'My.Tool.Name!', description: 'test')

      expect(tool.name).to eq('My_Tool_Name')
    end

    it 'truncates long tool names' do
      long_name = 'a' * 100
      tool = described_class.build(name: long_name)

      expect(tool.name.length).to eq(64)
    end

    it 'provides fallback name for empty input' do
      tool = described_class.build(name: '')

      expect(tool.name).to eq('tool')
    end

    it 'converts nil description to empty string' do
      tool = described_class.build(name: 'search')

      expect(tool.description).to eq('')
    end
  end

  describe '.from_hash' do
    it 'parses from hash with symbol keys' do
      tool = described_class.from_hash({ name: 'search', description: 'Search', parameters: { type: 'object' } })

      expect(tool.name).to eq('search')
      expect(tool.description).to eq('Search')
      expect(tool.parameters).to eq({ type: 'object' })
    end

    it 'parses from hash with string keys' do
      tool = described_class.from_hash({ 'name' => 'search', 'description' => 'Search' })

      expect(tool.name).to eq('search')
      expect(tool.description).to eq('Search')
    end

    it 'accepts input_schema as alias for parameters' do
      tool = described_class.from_hash({ name: 'search', input_schema: { type: 'object' } })

      expect(tool.parameters).to eq({ type: 'object' })
    end

    it 'accepts source parameter' do
      tool = described_class.from_hash({ name: 'search', source: { type: :extension } })

      expect(tool.source).to eq({ type: :extension })
    end

    it 'overrides source with keyword arg' do
      tool = described_class.from_hash(
        { name: 'search', source: { type: :builtin } },
        source: { type: :override }
      )

      expect(tool.source).to eq({ type: :override })
    end
  end

  describe '.from_registry_entry' do
    it 'creates from registry entry with tool_class' do
      entry = {
        name: 'ruby',
        description: 'Run Ruby code',
        input_schema: { type: 'object' },
        tool_class: 'RubyTool',
        extension: 'legion-code',
        runner: 'RubyRunner',
        function: :execute
      }
      tool = described_class.from_registry_entry(entry)

      expect(tool.name).to eq('ruby')
      expect(tool.description).to eq('Run Ruby code')
      expect(tool.parameters).to eq({ type: 'object' })
      expect(tool.source[:type]).to eq(:registry)
      expect(tool.source[:extension]).to eq('legion-code')
    end

    it 'creates from registry entry without tool_class' do
      entry = {
        name: 'custom',
        description: 'Custom tool',
        parameters: {},
        extension: 'custom-ext'
      }
      tool = described_class.from_registry_entry(entry)

      expect(tool.source[:type]).to eq(:extension)
    end
  end

  describe '.sanitize_tool_name' do
    it 'replaces dots with underscores' do
      expect(described_class.sanitize_tool_name('my.tool')).to eq('my_tool')
    end

    it 'removes special characters' do
      expect(described_class.sanitize_tool_name('my-tool!@#')).to eq('my-tool')
    end

    it 'preserves alphanumeric, underscores, and hyphens' do
      expect(described_class.sanitize_tool_name('my-tool_123')).to eq('my-tool_123')
    end
  end

  describe '#to_h' do
    it 'serializes to hash with name, description, parameters' do
      tool = described_class.build(
        name: 'search',
        description: 'Search the web',
        parameters: { type: 'object' }
      )
      hash = tool.to_h

      expect(hash).to eq(
        name: 'search',
        description: 'Search the web',
        parameters: { type: 'object' }
      )
    end

    it 'omits nil values' do
      tool = described_class.new('search', '', nil, nil)
      hash = tool.to_h

      expect(hash).to eq(name: 'search')
    end
  end

  describe 'round-trip' do
    it 'preserves values through from_hash/to_h' do
      original = { name: 'search', description: 'Search', parameters: { type: 'object' } }
      tool = described_class.from_hash(original)
      serialized = tool.to_h

      expect(serialized[:name]).to eq('search')
      expect(serialized[:description]).to eq('Search')
      expect(serialized[:parameters]).to eq({ type: 'object' })
    end
  end
end
