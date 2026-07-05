# frozen_string_literal: true

require 'spec_helper'

# Shared stop_reason vocabulary. Provider wire formats spell the same six
# canonical end-states differently (OpenAI/vLLM: "tool_calls"; Anthropic:
# "tool_use"; "stop" vs "end_turn" vs "eos"). Before this module, every
# provider translator carried its own copy-pasted *_STOP_REASON_MAP, which
# drifted — vllm/ollama mapped only "tool_use" and silently fell back to
# :end_turn on the "tool_calls" that OpenAI-compatible backends actually send.
#
# StopReasonMapping puts the common vocabulary in one place (inherited by all)
# with a provider-overridable additions hook and a full-replace hook.
RSpec.describe Legion::Extensions::Llm::StopReasonMapping do
  let(:host_class) do
    Class.new { include Legion::Extensions::Llm::StopReasonMapping }
  end
  let(:host) { host_class.new }

  describe 'the common vocabulary (#stop_reason_lookup)' do
    it 'maps OpenAI/vLLM "tool_calls" to :tool_use' do
      expect(host.stop_reason_lookup('tool_calls')).to eq(:tool_use)
    end

    it 'maps Anthropic "tool_use" to :tool_use' do
      expect(host.stop_reason_lookup('tool_use')).to eq(:tool_use)
    end

    it 'maps "stop"/"end_turn"/"eos" to :end_turn' do
      expect(host.stop_reason_lookup('stop')).to eq(:end_turn)
      expect(host.stop_reason_lookup('end_turn')).to eq(:end_turn)
      expect(host.stop_reason_lookup('eos')).to eq(:end_turn)
    end

    it 'maps "length"/"max_tokens" to :max_tokens' do
      expect(host.stop_reason_lookup('length')).to eq(:max_tokens)
      expect(host.stop_reason_lookup('max_tokens')).to eq(:max_tokens)
    end

    it 'coerces non-string keys via to_s' do
      expect(host.stop_reason_lookup(:tool_calls)).to eq(:tool_use)
    end

    it 'returns nil for an unmapped key (caller decides the default)' do
      expect(host.stop_reason_lookup('totally_unknown')).to be_nil
    end
  end

  describe 'provider additions (#stop_reason_map_additions)' do
    it 'base returns {} so no guard is ever needed' do
      expect(host.stop_reason_map_additions).to eq({})
    end

    it 'a provider adds provider-specific strings on top of the common map' do
      bedrock_like = Class.new do
        include Legion::Extensions::Llm::StopReasonMapping

        def stop_reason_map_additions
          { 'guardrail_intervened' => :content_filter }
        end
      end.new

      # addition resolves
      expect(bedrock_like.stop_reason_lookup('guardrail_intervened')).to eq(:content_filter)
      # common vocabulary still inherited
      expect(bedrock_like.stop_reason_lookup('tool_calls')).to eq(:tool_use)
    end

    it 'additions win over the common map on key collision' do
      override = Class.new do
        include Legion::Extensions::Llm::StopReasonMapping

        def stop_reason_map_additions
          { 'stop' => :stop_sequence }
        end
      end.new

      expect(override.stop_reason_lookup('stop')).to eq(:stop_sequence)
    end
  end

  describe 'full replacement (#stop_reason_map)' do
    it 'a provider can replace the whole map, dropping the defaults' do
      replaced = Class.new do
        include Legion::Extensions::Llm::StopReasonMapping

        def stop_reason_map
          { 'weird_only' => :end_turn }
        end
      end.new

      expect(replaced.stop_reason_lookup('weird_only')).to eq(:end_turn)
      expect(replaced.stop_reason_lookup('tool_calls')).to be_nil
    end
  end
end
