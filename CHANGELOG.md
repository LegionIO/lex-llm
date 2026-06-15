# Changelog

## 0.5.2 - 2026-06-15

### Added
- **CapabilityPolicy module** — Shared capability resolution with 7-layer precedence chain (model_override > instance_override > provider_override > model_metadata > provider_catalog > probe > provider_envelope > default_false). All optional capabilities default false.
- **Boolean aliases** — `enable_thinking`, `tools_flag`, `embedding_flag`, etc. map to canonical capability keys at any settings level.
- **ModelOffering#capability_sources** — Per-capability source metadata preserved through offering serialization.
- **Provider#offering_from_model** — Base class now generates `:model_metadata` source tags for capabilities from provider API responses.

## 0.5.1 - 2026-06-12

### Fixed
- **ToolDefinition constants** — Move `OBJECT_SCHEMA_KEYWORDS` and `COMPOSITE_SCHEMA_KEYWORDS` out of `Data.define` block to satisfy `Lint/ConstantDefinitionInBlock`.
- **ToolSchema documentation** — Add top-level module documentation comment.
- **Conformance spec cleanup** — Remove unused block argument from shared examples, fix duplicate describe block and context wording in tool_definition_spec.
- **RuboCop clean** — Zero offenses across 140 files.

## 0.5.0 - 2026-06-10

### Added
- **Canonical types module** — `Legion::Extensions::Llm::Canonical` provides immutable `Data.define` value objects (Thinking, Usage, Params, ContentBlock, ToolDefinition, ToolCall, Message, Request, Response, Chunk) forming the single N×N client↔provider routing contract. Includes `from_hash`/`to_h` for serialization, `CONTRACT_VERSION` for provider gem compatibility checks, and explicit factory validation per Amendment A.
- **Conformance kit** — Shared RSpec example groups shipped under `spec/legion/extensions/llm/conformance/` (provider_translator_examples, client_translator_examples) with JSON fixtures for canonical↔provider translation contract testing. Packaged via gemspec `spec.files`; `gemspec.require_paths` remains `['lib']` only — conformance specs are consumed by provider gems at test time via `Gem.loaded_specs['lex-llm'].full_gem_path`.
- **Conformance kit coordinator** — Fixtures read with explicit UTF-8 encoding so locale-less CI shells do not fail on JSON.parse.

### Changed
- **Zeitwerk autoloading removed** — Replaced lazy Zeitwerk::Loader with deterministic explicit `require_relative` for every file in `lib/`. Contract constants now exist at `require` time so provider gems can subclass against them during phased extension loading (core → lex-identity → lex-llm → lex-llm-*). Removed undeclared `zeitwerk ~> 2` runtime dependency from gemspec. Load order: canonical types and base classes first, then components referencing them. Transport exchange/message modules remain as Ruby `autoload` to avoid forcing `legion-transport` at boot time.

## 0.4.19 - 2026-06-10

### Fixed
- **Connection logging bodies** — `setup_logging` now enables request body logging when the logger is at DEBUG level OR when `fleet.request.logger.request_payload` is explicitly true. Previously relied solely on log-level check; the new `request_payload` setting provides explicit control for fleet worker scenarios.
- **OpenAI-compatible tool formatting** — `format_openai_tools` now handles both `ToolDefinition` objects and plain Hashes (from `native_dispatch`) by checking `respond_to?` for method access and falling back to symbol/string key access. Prevents `NoMethodError` when tools arrive as hash-backed definitions.

### Added
- **Fleet request_payload setting** — Added `fleet.request.logger.request_payload` (default: `false`) to `default_settings` for explicit control over request body logging in Faraday middleware.

## 0.4.18 - 2026-06-05

### Fixed
- **Test suite** — All 377 specs passing. Specs exercise shared streaming, chat, models, fleet, credential sources, and provider contract behavior.
- **RuboCop** — Zero offenses across 110 files.

## 0.4.17 - 2026-06-04

### Added
- **faraday-typhoeus dependency** — Added `faraday-typhoeus >= 0.2` as a runtime dependency. Connection middleware now prefers `:typhoeus` (libcurl) adapter over `:net_http` to work around Ruby 4.0 + net-http-0.9.1 SSL keep-alive issues that drop connections mid-read (`connection.rb`)

### Fixed
- **Streaming on_data rejects status 0/nil** — `v2_on_data` handler only accepted `env&.status == 200`, causing typhoeus streaming chunks (where status is nil or 0 during active streaming before headers arrive) to be treated as failed responses. Now accepts nil/0 status as valid streaming state (`streaming.rb`)

## 0.4.16 - 2026-05-31

### Security
- **FLEET-01**: `FleetRequest`, `FleetResponse`, and `FleetError` now encrypt via `Legion::Crypt` when `fleet.compliance.encrypt_fleet` is true (default). Node-to-node inference traffic with PHI was previously plaintext on AMQP.
- **FLEET-02**: JWT `verify_issuer` set to `true` — library now validates issuer claim cryptographically.
- **FLEET-03**: Hashable JWT claims (params, caller, message_context, trace_context) validated via content hash only. No raw PHI values in base64 JWT payloads.
- **CRED-01**: Credential source probing (claude/codex config files) gated behind `extensions.llm.security.credential_source_probing` setting. Disableable in production.
- **OPENAI-CRED-01**: Bearer token filter added to Faraday response logger — API keys redacted as `Bearer [REDACTED]` in debug output.

### Fixed
- **FLEET-04**: `validate_policy!` no longer blocks all traffic when `require_policy` is enabled — logs warning and allows instead of raising unconditionally.
- **FLEET-IDEMPOTENCY-01**: 100k entry cap on replay JTI cache and idempotency cache with LRU eviction under memory pressure.

## 0.4.15 - 2026-05-21

- Add `identity_headers` to base provider — all API calls now include x-legion-identity-* headers when Identity is resolved
- Add `offering_transport` and `offering_tier` instance methods with class-level `default_transport`/`default_tier` overrides
- Add `runtime_provider_setting` fallback for model_whitelist/blacklist from Legion::Settings
- Remove duplicate `offering_transport`/`offering_tier` definitions


## 0.4.14 - 2026-05-16

- Normalize `function_calling`, `functions`, and related tool-use capability aliases to include canonical `:tools` on model metadata and routing offerings.
- Keep provider compatibility aliases while allowing capability filters to reliably match tool-capable models.

## 0.4.13 - 2026-05-15

- Strip provider thinking from OpenAI-compatible responses when local models emit `<thinking>` tags or untagged initial reasoning preambles, and keep those hidden from live streaming content deltas.

## 0.4.12 - 2026-05-15

- Preserve streamed provider error bodies in a custom Faraday env key so Faraday Net::HTTP finalization cannot replace the buffered body with an empty string before `ErrorMiddleware` parses it.

## 0.4.11 - 2026-05-15

- Fix `handle_failed_response` to preserve non-200 streaming error bodies across chunks instead of swallowing `ParseError` and falling through to a generic "An unknown error occurred". Complete JSON error bodies still raise typed provider errors immediately; incomplete bodies are buffered onto the Faraday response env for final middleware parsing, with regex fallback extraction for vLLM-style partial `message` fields when the env cannot carry the buffered body.

## 0.4.10 - 2026-05-13

- Add cache-backed `model_detail` lookup with 24-hour TTL; nil results are not cached; `fetch_model_detail` hook for subclasses to override with live API calls.
- Build `model_detail_cache_key` from tier, slug, instance, and credential fingerprint so remote providers never share model detail entries across credentials.
- Add `credential_cache_fragment` — includes an 8-char SHA-256 credential fingerprint in cache keys for non-local providers.
- Add `source_tag`, `credential_fingerprint`, and `config_fingerprint` to `CredentialSources` for provenance tracking across discovered instances.
- Suppress Faraday raw stacktrace dumps on connection failures by setting `errors: false` on the response logger middleware.
- Rescue `Faraday::ConnectionFailed` in `discover_offerings` and return an empty list with a concise warning instead of propagating the exception.
- Wire `model_allowed?` filtering into `discover_offerings` so whitelist/blacklist settings are enforced during live discovery (was dead code before).
- Check instance config first for `model_whitelist`/`model_blacklist` before falling back to provider settings, enabling per-instance override.
- Add `legion-cache >= 1.3.0` as a runtime dependency and include `Legion::Cache::Helper` in the base `Provider` class.

## 0.4.9 - 2026-05-13

- Route provider, tool, streaming, model, attachment, connection, credential, and fleet diagnostics through `Legion::Logging::Helper`.
- Replace temporary provider and stream probes with helper-backed debug logs that preserve model, tool, parameter, and header-key context without stdout or fatal-level noise.
- Add handled debug exception logging around provider discovery, credential probes, and fleet cleanup fallbacks.
- Fix provider request debug logging when callers pass tools as a hash.

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
