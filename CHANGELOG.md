# Changelog

## 0.1.9 - 2026-04-30

- Replace Model::Info class with immutable Data.define value object supporting new fields: instance, parameter_count, parameter_size, quantization, size_bytes, modalities_input, modalities_output
- Add Model::Info.from_hash factory for backward-compatible construction from legacy hash format
- Add backward-compatible accessors on Model::Info for context_window, max_output_tokens, created_at, knowledge_cutoff, modalities, pricing, type, and legacy capability predicates
- Add model_allowed? to base Provider with whitelist/blacklist filtering from settings
- Add multi-host base_url resolution with TLS awareness and reachability probing
- Add cache tier selection helpers: cache_local_instance?, model_cache_get/set/fetch, cache_instance_key for local vs shared cache routing
- Add shared transport classes for llm.registry exchange and registry event messages (guarded by defined? for optional legion-transport)
- Add shared RegistryPublisher parameterized by provider_family for all lex-llm-* gems
- Add shared RegistryEventBuilder parameterized by provider_family for all lex-llm-* gems
- Mark Provider.register, .resolve, .for, .providers with @deprecated annotations for future removal in favor of the extension registry

## 0.1.8 - 2026-04-30

- Audit all rescue blocks for handle_exception compliance
- Add Legion::Logging::Helper to Provider, Chat, and Models for structured exception reporting
- Replace ad-hoc logger.debug/warn calls in rescue blocks with handle_exception across streaming, chat, models, and provider modules
- Add require for legion/logging in the main entrypoint

## 0.1.7 - 2026-04-30

- Add thinking extraction from OpenAI-compatible streaming chunks (reasoning_content, reasoning, think tags)
- Add stream_usage_supported? opt-in for streaming token usage reporting
- Add filtered_chunk method to StreamAccumulator for clean thinking/content separation
- Wrap streaming callback through accumulator filter for proper SSE event routing

## 0.1.6 - 2026-04-28

- Add provider-neutral registry event envelopes for future `llm.registry` offering availability, unavailability, degraded, and heartbeat publishing without persistence.
- Sanitize registry offering payloads and reject sensitive runtime, capacity, health, lane, and metadata keys before publication.

## 0.1.5 - 2026-04-28

- Add the expanded provider-neutral model offering contract with offering IDs, provider instances, canonical model aliases, model families, and routing metadata.
- Add shared model alias normalization and an in-memory offering registry for common routing filters.

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
