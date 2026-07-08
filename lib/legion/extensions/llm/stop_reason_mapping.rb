# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Shared stop_reason vocabulary, included by every provider translator (and
      # available to legion-llm, which depends on lex-llm). Provider wire formats
      # spell the same canonical end-states differently — OpenAI/vLLM emit
      # "tool_calls", Anthropic "tool_use", and "stop"/"end_turn"/"eos" all mean
      # the same thing. This puts the common vocabulary in one place so it is not
      # copy-pasted (and drifting) across five provider gems.
      #
      # Keys are the incoming provider strings; values are the canonical
      # stop_reason (see Canonical::Response::STOP_REASONS).
      #
      # Provider overrides, all by plain method definition — no guards:
      #   * ADD provider-specific strings  → override #stop_reason_map_additions
      #   * REPLACE the whole vocabulary   → override #stop_reason_map
      module StopReasonMapping
        # The common vocabulary every provider inherits for free.
        def stop_reason_map
          {
            'stop' => :end_turn,
            'end_turn' => :end_turn,
            'eos' => :end_turn,
            'complete' => :end_turn,
            'tool_calls' => :tool_use,
            'tool_call' => :tool_use,
            'tool_use' => :tool_use,
            'function_call' => :tool_use,
            'length' => :max_tokens,
            'max_tokens' => :max_tokens,
            'stop_sequence' => :stop_sequence,
            'stop_sequences' => :stop_sequence,
            'content_filter' => :content_filter,
            'error' => :error
          }
        end

        # Provider-specific additions, merged on top of the common map. Base
        # returns {} so callers never need an "if defined?" guard. Additions win
        # over the common map on key collision.
        def stop_reason_map_additions
          {}
        end

        # Resolve a provider wire stop_reason string to its canonical symbol, or
        # nil when unmapped (the caller decides the default — usually :end_turn).
        def stop_reason_lookup(key)
          stop_reason_map.merge(stop_reason_map_additions).fetch(key.to_s, nil)
        end
      end
    end
  end
end
