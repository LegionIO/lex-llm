# B1b — Conformance Kit (lex-llm spec support)

> **Status:** Complete (self-test green: 54 examples, 0 failures)
> **Date:** 2026-06-10
> **Repo:** lex-llm (conformance kit only)
> **Branch:** feat/canonical-types
> **Design doc:** 2026-06-09-nxn-canonical-routing-design.md Amendment B
> **Implementation plan:** Phase 2 (conformance kit in lex-llm)
> **Dependency:** B1a canonical types (coordinator commit e1cbf820)
> **Self-test green:** `bundle exec rspec spec/legion/extensions/llm/conformance` → 54 examples, 0 failures

---

## What was delivered

### Shared example groups

**provider_translator_examples.rb** (~390 lines)
`it_behaves_like 'a canonical provider translator'` — 54 scenarios across render_request,
parse_response, parse_chunk, stop_reason, round-trip.

**client_translator_examples.rb** (~270 lines)
Mirror group for client translators: `it_behaves_like 'a canonical client translator'` —
parse_request/format_request round-trip, format_response, format_chunk, format_error.

### Fixture corpus (19 JSON files)

All under `spec/legion/extensions/llm/conformance/fixtures/`:
- simple_text request/response, system_prompt, params_mapping (all 10 G18 fields),
  tools_request, tool_use_response, tool_results_continuation_request (enhanced: mixed client + registry tool calls per G4)
- canonical_thinking_request.json
- canonical_thinking_response.json (thinking content + signature, thinking_tokens)
- canonical_empty_response.json
- canonical_error_response.json
- canonical_stop_reason_matrix.json (6 canonical enums + 5 provider mappings)
- canonical_streaming_text_chunks.json
- canonical_streaming_thinking_chunks.json (thinking + text + signature + done)
- canonical_streaming_tool_call_chunks.json (multi-chunk tool-call identity per A7)
- canonical_streaming_error_chunks.json (**new**: mid-stream error per G5/G6)
- canonical_streaming_accumulated_response.json (**new**: expected assembled response from tool-call chunks)
- canonical_fleet_round_trip.json (per R6)
- canonical_metering_audit_events.json (per G15e: schemas + example events)

### Self-test echo translator

Echo translator + spec that passes both provider and client translator groups, proving the shared examples work correctly.

### Infrastructure fixes

1. **lex-llm.gemspec** — spec.files now includes spec/ (was excluded); spec.require_paths adds 'spec' — enables cross-gem conformance kit loading per the amended Phase 2 spec.
2. .rubocop.yml — excluded conformance directory from RSpec/SpecFilePathFormat.
3. **provider_translator_examples.rb** — parse_response now tests translator.parse_response(wire) instead of canonical::Response.from_hash(fixture).

### Issues found & fixed during this session

1. **parse_response tests didn't exercise the translator** — Fixed by using `fixture_symbolized` + calling `translator.parse_response(wire).
2. **Malformed rubocop directives in canonical lib files** — 5 files had `# rubocop:disable Metrics/ParameterLists, Metrics/PerceivedComplexity -- factory` where the trailing `, --` triggered `Lint/CopDirectiveSyntax`. Fixed & committed.
3. **RSpec/SpecFilePathFormat rubocop violation** — `echo_translator_spec.rb` in `spec/legion/extensions/llm/conformance/` triggered the cop. Excluded conformance directory.
4. **Symbolized vs string-keyed fixtures** — Fixed by using `fixture_symbolized` for self-test.

---

## Test results

Conformance kit: 54 examples, 0 failures
Full test suite: 630 examples, 0 failures
Line coverage: 79.01% (3569 / 4517)
Branch coverage: 52.76% (908 / 1721)
RuboCop: clean (136 files, 0 offenses)

---

## Next steps

1. **Phase 3** — Provider gems adopt the kit (anthropic first, then openai, vllm, ollama, bedrock). Each runs `it_behaves_like 'a canonical provider translator'`.
2. **Phase 5** — Client translators in legion-llm adopt the client shared examples.
3. **Bug fix** — Resolve ToolCall.from_hash JSON::ParserError constant resolution in lib/canonical (feat/canonical-types branch). The coordinator commit e1cbf820 fixed this with `Legion::JSON`.
4. **Provider-specific fixtures** — Real provider gems will supply their own wire-format fixtures; the canonical fixtures serve as the round-trip anchor. A future step would add anthropic/openai wire-format reference fixtures (sanitized from `legionio-e2e/results/`) for direct cross-verification.
5. **Streaming tool-call incremental fragments** — The `canonical_streaming_tool_call_chunks.json` fixture carries complete (canonical-form) tool call args per chunk due to the ParserError bug. The fix in #3 allows incremental fragments if desired.