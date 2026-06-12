# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/provider/open_ai_compatible'
require 'legion/extensions/llm/message'
require 'legion/extensions/llm/tool_call'

# Failing-test for the legionio-e2e claude/openai legionio_tool_injection
# regression. After the LexLLMAdapter#normalize_message_tool_calls fix
# (legion-llm 4317d56), the adapter now emits Array<ToolCall> on the
# assistant message — which is the historical canonical shape per
# canonical/message.rb:75 ("Array is canonical; Hash is legacy lex-llm
# format (name → ToolCall)"). The OpenAI-compatible HTTP payload renderer
# missed that update and still calls `.values` on tool_calls, so live
# requests now blow up with:
#
#   undefined method 'values' for an instance of Array
#
# (captured at
#  legionio-e2e/results/claude/openai_legionio_tool_injection_returns_response_containing_legionio_tool_references_response.json)
#
# The bedrock provider (format_invoke_model_assistant) and the
# lex-llm-openai canonical translator (translator.rb:290) already handle
# both shapes via `tool_calls.is_a?(Hash) ? .values : Array(...)`. This
# spec pins the same shape-tolerance for OpenAICompatible.
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
    Legion::Extensions::Llm::ToolCall.new(
      id: 'call_001',
      name: 'legion_list_all_tools',
      arguments: { 'filter' => 'all' }
    )
  end

  it 'renders an Array<ToolCall> (the post-canonical shape)' do
    rendered = host.format_openai_tool_calls([tool_call])
    expect(rendered).to be_an(Array)
    expect(rendered.size).to eq(1)
    expect(rendered.first[:id]).to eq('call_001')
    expect(rendered.first[:type]).to eq('function')
    expect(rendered.first[:function][:name]).to eq('legion_list_all_tools')
  end

  it 'renders a Hash<id, ToolCall> (legacy lex-llm shape) without regression' do
    rendered = host.format_openai_tool_calls({ call_id: tool_call })
    expect(rendered).to be_an(Array)
    expect(rendered.size).to eq(1)
    expect(rendered.first[:function][:name]).to eq('legion_list_all_tools')
  end

  it 'returns nil when tool_calls is nil or empty' do
    expect(host.format_openai_tool_calls(nil)).to be_nil
    expect(host.format_openai_tool_calls([])).to be_nil
    expect(host.format_openai_tool_calls({})).to be_nil
  end
end
