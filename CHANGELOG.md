# Changelog

## 0.4.9 - 2026-05-13

- Route provider, tool, streaming, model, attachment, connection, credential, and fleet diagnostics through `Legion::Logging::Helper`.
- Replace temporary provider and stream probes with helper-backed debug logs that preserve model, tool, parameter, and header-key context without stdout or fatal-level noise.
- Add handled debug exception logging around provider discovery, credential probes, and fleet cleanup fallbacks.

## 0.4.8 - 2026-05-11

- Set `remote_invocable?` to false — this extension does not need remote AMQP topology (exchanges, queues, DLX).

## 0.4.7 - 2026-05-08

- Unpack legacy nested fleet `options` before provider dispatch so `system` and `tools` arrive as normal provider keyword arguments.

## 0.4.6 - 2026-05-07

- Render OpenAI-compatible embedding payloads with the canonical model id when callers pass `Model::Info` objects.
- Preserve streamed OpenAI-compatible tool-call argument fragments until the accumulator can assemble and parse the full JSON payload.
- Treat malformed accumulated streaming tool arguments as handled provider output and return empty arguments instead of raising.

## 0.4.5 - 2026-05-07

- Add `ProviderSettings.infer_tier_from_endpoint(url)` shared utility: returns `:local` for localhost/loopback endpoints, `:direct` for all other hosts. Handles `URI::InvalidURIError` and nil safely.

## 0.4.4 - 2026-05-07

- Fix `confirm_publish` to call `wait_for_confirms` with no arguments, matching bunny 3.1.0 API which removed the timeout parameter.
- Fix `prepare_publisher_confirms` to pass `confirm_timeout:` to `confirm_select` when `publish_confirm_timeout_ms` is set.

## 0.4.3 - 2026-05-06

- Move provider-owned fleet responder execution into `lex-llm` so provider gems no longer depend on `legion-llm`.
- Add shared responder-side fleet token validation, idempotency protection, provider dispatch, and response/error publishing helpers.
- Reserve fleet replay tokens before provider dispatch, split replay TTL into auth settings, and raise explicit responder transport configuration errors.

## 0.4.2 - 2026-05-06

- Remove the temporary settings logger wrapper and lazy-load fleet transport envelopes so `lex-llm` boot does not force `legion-transport` loading.

## 0.4.1 - 2026-05-06

- Make `AutoRegistration` a pure provider discovery mixin and remove upward `Legion::LLM::Call::Registry` mutation hooks.
- Add provider alias metadata so `legion-llm` can register compatibility provider families without provider require-time side effects.
- Pass live discovery flags and filters through from `Provider#discover_offerings` to `#list_models`.
- Merge provider-specific embedding params into canonical `Provider#embed` request payloads.

## 0.4.0 - 2026-05-06

- Set the coordinated sweep dependency floor for provider-owned fleet responders.
- Make `Provider#discover_offerings(live: false)` serve only cached live discovery results so inventory reads do not probe provider endpoints.

## 0.3.6 - 2026-05-06

- Replace shared fleet request, response, and error envelopes with strict fleet protocol v2 fields.
- Reject legacy fleet envelope fields and publish provider replies through the AMQP default exchange reply queue with optional mandatory routing and publisher confirms.

## 0.3.5 - 2026-05-06

- Add shared response normalization value objects for chat, stream, embedding, and thinking extraction.
- Strip provider thinking from caller-visible OpenAI-compatible completion content, including malformed trailing close-tag output.
- Preserve provider reasoning metadata while tolerating streaming tool-call deltas without optional function names.

## 0.3.4 - 2026-05-06

- Add shared provider contract and unsupported capability error namespace for lex-llm provider gems.
- Require keyword provider embed/count token calls and validate provider settings instance nesting.
- Move shared fleet defaults under nested consumer/auth settings.

## 0.3.3 - 2026-05-03

- Fix OpenAI-compatible streaming to keep split `<think>` tag content out of streamed assistant content.
- Strip leaked assistant thinking from outbound OpenAI-compatible history, including dangling close-tag content from prior responses.
- Tolerate incomplete streaming tool-call deltas that omit `function.name`.

## 0.3.2 - 2026-05-03

- Fix AutoRegistration to pass the discovered instance id into provider adapter config for instance-aware model offerings

## 0.3.1 - 2026-05-02

- Fix AutoRegistration to pass tier and capabilities metadata to Call::Registry on registration

## 0.3.0 - 2026-05-01

- Add CredentialSources helper: read-only probes for env vars, ~/.claude/settings.json, ~/.codex/auth.json, Legion::Settings, socket/HTTP probes, SHA-256 credential dedup
- Add AutoRegistration mixin: shared discover_instances/register_discovered_instances/rediscover! for lex-llm-* provider self-registration into Call::Registry
- Delete Provider.register, .resolve, .for, .providers, .local_providers, .remote_providers, .configured_providers, .configured_remote_providers — replaced by Call::Registry
- Delete Configuration.register_provider_options — providers accept plain Hash config via new HashConfig wrapper
- Provider#initialize accepts plain Hash in addition to Configuration objects
- Models module uses Call::Registry with namespace-scanning fallback for standalone usage

## 0.2.0 - 2026-04-30

- Promote ModelInfo Data.define value object with immutable fields: instance, parameter_count, parameter_size, quantization, size_bytes, modalities_input, modalities_output
- Formalize provider contract: model_allowed? whitelist/blacklist filtering, multi-host base_url resolution with TLS awareness and reachability probing, normalize_url for consistent endpoint formatting
- Add cache tier selection helpers: cache_local_instance?, model_cache_get/set/fetch, cache_instance_key for local vs shared cache routing
- Add shared transport classes and RegistryPublisher/RegistryEventBuilder parameterized by provider_family for all lex-llm-* gems
- Deprecate Provider.register, .resolve, .for, .providers in favor of the extension registry

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
