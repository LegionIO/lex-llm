# frozen_string_literal: true

# Shared examples for provider tool rendering conformance.
# Include in any provider gem that renders tools to prove it handles
# canonical ToolDefinition objects, Hashes, and schemas without double-wrap.
#
# Usage in provider specs:
#   it_behaves_like 'canonical tool rendering', described_class.new(...)
#
RSpec.shared_examples 'canonical tool rendering' do # rubocop:disable RSpec/MultipleMemoizedHelpers
  let(:full_schema) { { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] } }

  let(:canonical_tool) do
    Legion::Extensions::Llm::Canonical::ToolDefinition.build(
      name: 'get_weather',
      description: 'Weather lookup',
      parameters: full_schema
    )
  end

  let(:hash_tool_parameters) do
    { name: 'get_weather', description: 'Weather lookup', parameters: full_schema }
  end

  let(:hash_tool_input_schema) do
    { name: 'get_weather', description: 'Weather lookup', input_schema: full_schema }
  end

  let(:hash_tool_params_schema) do
    { name: 'get_weather', description: 'Weather lookup', params_schema: full_schema }
  end

  let(:tools_map) { { 'get_weather' => canonical_tool } }

  describe 'canonical tool rendering' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    it 'accepts Canonical::ToolDefinition without raising' do
      expect { render_tools(tools_map) }.not_to raise_error
    end

    it 'renders schema with top-level type: object' do
      rendered = render_tools(tools_map)
      schema = extract_rendered_schema(rendered)
      expect(schema[:type] || schema['type']).to eq('object')
    end

    it 'renders properties without double-wrap' do
      rendered = render_tools(tools_map)
      schema = extract_rendered_schema(rendered)
      props = schema[:properties] || schema['properties']
      expect(props).not_to have_key(:type)
      expect(props).not_to have_key('type')
      expect(props).to have_key(:city).or have_key('city')
    end

    it 'renders Hash tools with :parameters identically to canonical' do
      map = { 'get_weather' => hash_tool_parameters }
      rendered = render_tools(map)
      schema = extract_rendered_schema(rendered)
      expect(schema[:type] || schema['type']).to eq('object')
      expect(schema[:properties] || schema['properties']).to have_key(:city).or have_key('city')
    end

    it 'renders Hash tools with :input_schema identically' do
      map = { 'get_weather' => hash_tool_input_schema }
      rendered = render_tools(map)
      schema = extract_rendered_schema(rendered)
      expect(schema[:type] || schema['type']).to eq('object')
    end

    it 'renders Hash tools with :params_schema identically' do
      map = { 'get_weather' => hash_tool_params_schema }
      rendered = render_tools(map)
      schema = extract_rendered_schema(rendered)
      expect(schema[:type] || schema['type']).to eq('object')
    end
  end
end
