# Changelog

## 0.1.4 - 2026-04-28

- Add non-live provider readiness metadata for routing without expensive health or model calls by default.
- Map OpenAI-compatible model listings to normalized capabilities and modalities for routing.

## 0.1.3 - 2026-04-27

- Convert the gem to a standard Legion extension runtime under `Legion::Extensions::Llm`.
- Remove the fork-era compatibility namespace, Rails railtie, generators, rake tasks, dummy app, and ActiveRecord helpers.
- Move provider-neutral chat, schema, model, routing, streaming, and fleet primitives under `lib/legion/extensions/llm`.

## 0.1.2 - 2026-04-27

- Add a shared OpenAI-compatible provider adapter for `lex-llm-openai`, `lex-llm-vllm`, `lex-llm-mlx`, and other compatible servers.

## 0.1.1 - 2026-04-27

- Remove fork-carried concrete provider implementations and VCR-backed provider specs from the base gem.
- Add fake-provider end-to-end specs for shared chat, tools, schemas, embeddings, moderation, images, transcription, model lookup, and fleet lane wiring.
- Add shared provider settings construction for `lex-llm-*` gems.
- Make base defaults provider-neutral and move provider-specific defaults into provider gems.

## 0.1.0 - 2026-04-26

- Rename the forked base gem to `lex-llm` with Legion extension integration.
- Add provider-neutral routing metadata for concrete model offerings and shared fleet lane keys.
- Use Legion JSON/settings/logging runtime dependencies for shared extension behavior.
- Remove the upstream RubyLLM docs site and issue templates from the LegionIO fork.
