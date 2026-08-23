# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/provider/open_ai_compatible'

# Regression pin for the legionio-e2e claude/openai legionio_tool_injection
# defect: the renderer must handle Array<Canonical::ToolCall> (the canonical
# shape). 0.8.0: the legacy Hash shape is deleted (O03a/L4 — Array only).
RSpec.describe Legion::Extensions::Llm::Provider::OpenAICompatible do
  let(:host_class) do
    Class.new do
      include Legion::Extensions::Llm::Provider::OpenAICompatible

      # Expose the otherwise-private renderer so we can test it directly
      # without booting a full provider stack.
      public :format_openai_tool_calls
    end
  end

  let(:host) { host_class.new }

  let(:tool_call) do
    Legion::Extensions::Llm::Canonical::ToolCall.build(
      name: 'legion_list_all_tools',
      id: 'call_001',
      arguments: { 'filter' => 'all' }
    )
  end

  it 'renders an Array<Canonical::ToolCall>' do
    rendered = host.format_openai_tool_calls([tool_call])
    expect(rendered).to be_an(Array)
    expect(rendered.size).to eq(1)
    expect(rendered.first[:id]).to eq('call_001')
    expect(rendered.first[:type]).to eq('function')
    expect(rendered.first[:function][:name]).to eq('legion_list_all_tools')
    expect(Legion::JSON.parse(rendered.first[:function][:arguments])).to eq(filter: 'all')
  end

  it 'returns nil when tool_calls is nil or empty' do
    expect(host.format_openai_tool_calls(nil)).to be_nil
    expect(host.format_openai_tool_calls([])).to be_nil
  end
end
