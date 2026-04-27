# Changelog

## 0.1.2 - 2026-04-27

- Add a shared OpenAI-compatible provider adapter for `lex-llm-openai`, `lex-llm-vllm`, `lex-llm-mlx`, and other compatible servers.

## 0.1.1 - 2026-04-27

- Remove fork-carried concrete provider implementations and VCR-backed provider specs from the base gem.
- Add fake-provider end-to-end specs for shared chat, tools, schemas, embeddings, moderation, images, transcription, model lookup, and fleet lane wiring.
- Add shared provider settings construction for `lex-llm-*` gems.
- Make base defaults provider-neutral and move provider-specific defaults into provider gems.

## 0.1.0 - 2026-04-26

- Rename the forked base gem to `lex-llm` with `LexLLM` runtime namespaces and `Legion::Extensions::Llm` integration.
- Add provider-neutral routing metadata for concrete model offerings and shared fleet lane keys.
- Use Legion JSON/settings/logging runtime dependencies for shared extension behavior.
- Remove the upstream RubyLLM docs site and issue templates from the LegionIO fork.
