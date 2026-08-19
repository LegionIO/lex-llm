# Changelog

## 0.7.6 - 2026-08-19

### Added
- **Shared writer-cadence weight reconciliation.** `Inventory::WeightReconciler` atomically rebuilds write-time weights, publishes changed snapshots, protects unpublished activation state, and keeps cache/sequence mutation behind each writer's existing mutex. `DormantWeightTracker` reports configured weights with no published lane once per absence cycle. The shared machinery adds no Settings callback or lifecycle coupling.

### Fixed
- **`WeightReconciler` declares its direct `set` dependency.** Direct file loads no longer rely on another framework entrypoint having already initialized the process-global `Set` constant.

## 0.7.5 - 2026-08-19

### Added
- **Write-time lane weights on immutable Inventory records.** `Inventory::WeightSchema` computes the independent tier, provider, instance, and model-or-offering axes from current settings, preserving zero as an explicit disable and rejecting malformed values. `OfferingDraft`, `OfferingRecord`, and `LaneRecord` now carry an atomic validated weight pair; registry construction copies that frozen pair unchanged.

## 0.7.4 - 2026-08-19

### Added
- **Authoritative Inventory lane-type mapping.** `Taxonomies::OPERATION_TO_LANE_TYPE` and `Taxonomies.lane_type_for` now own the complete canonical operation-to-lane-type mapping used by human-readable five-tuple lane identities. The deletion-scheduled coordinator adapter delegates to the same resolver instead of retaining a divergent compatibility copy.

## 0.7.3 - 2026-08-17

### Fixed
- **Instance identity: `default` is no longer a reserved instance_id** — the name is an operator label; synthetic-default protection is provider-side (template-conditional discovery skip). `Inventory::Identity::InstanceKey` now accepts `instance_id: 'default'` as a plain label (v2 parity — v2 lane validation had no reserved-name concept and `:default` was the stock instance label). The reserved-value rule was invented in the 8/13 identity freeze with no rationale and never appeared in the frozen binding conformance fixture. The shared `'an SSOT v3 provider adapter'` conformance example was updated to the new semantics; provider gemspec floors bump to `>= 0.7.3` in the concurrent provider wave.

## 0.7.2 - 2026-08-17

### Fixed
- **`Canonical::Message.from_hash` projects onto known member keys.** The factory now builds via `build(**h.slice(*members))` (mirroring `Request.from_hash`) instead of passing the raw hash to a fixed kwarg list, so transport-only keys such as `:cache_control` (injected by the prompt-cache step on multi-message requests) are dropped instead of raising `ArgumentError: unknown keyword: :cache_control` before the HTTP request was ever sent.
- **`sanitized_reason` coerces non-UTF-8 reasons instead of raising.** Non-UTF-8 reasons (e.g. an ASCII-8BIT `ArgumentError` message) are now `force_encoding`'d to UTF-8 and `scrub`bed (`'?'`) rather than raising `ValidationError: reason is not valid UTF-8`, which masked the original dispatch error end-to-end (never logged) and produced a retriable 500. Non-String, empty, and oversized reasons still raise.

### Added
- **Regression specs for the dispatch-boundary fixes.** `Message.from_hash` with a transport-only `cache_control` key, and `ProviderOutcome` with a non-UTF-8 reason; both proven to fail pre-fix.
- **legion-settings floor raised to `>= 1.4.2`.** Its segments-based nested resolution fixes two-segment extensions resolving to a flat key (e.g. `:llm_vllm`) instead of `[:extensions][:llm][:vllm]`, which left `settings[:instances]` nil so SSOT discovery actors saw zero configured instances.

## 0.7.1 - 2026-08-14

### Fixed
- **Shared conformance fixtures now carry `metadata.model`.** SSOT v3 §9-compliant provider translators require an exact selected model to be present in the canonical request before `render_request` is called (they read `request.metadata[:model]`). The six request fixtures used by the shared `'a canonical provider translator'` examples previously carried no model, causing those conformance examples to fail for §9-compliant providers. Each fixture now includes `"metadata": { "model": "test-fixture-model" }`. No production behavior change; existing providers that fall back to a default model are unaffected.

## 0.7.0 - 2026-08-13

### Added
- **SSOT v3 provider runtime contract (additive).** A fully typed, process-local inventory and routing contract that lets a migrated provider construct a mandatory `Inventory::InstanceKey`, claim an exact instance for an opaque fenced `PublisherToken`, build immutable `OfferingDraft` values off-registry, run an immediate safe (non-inference) readiness probe, and atomically activate a callable, complete offering snapshot, derived operation lanes, and `available` state only when startup readiness succeeds. Includes:
  - `Inventory::Identity` with the length-framed SHA-256 `off:v1:`/`lane:v1:` encoders (tier is never an identity input) and binding identity fixtures.
  - `Inventory` evidence, `OfferingDraft`/`OfferingRecord`/`LaneRecord`/`AvailabilityFact`/`ReadinessResult`/`InstanceRecord`/`PublicationStatus`/`MutationResult` immutable records, `CallableHandle`/`DispatchLease` lifecycle, `PublisherToken`/`ProbeToken`/`ProbeRequest`, `ProbeCoordinator`, and the synchronized `Registry` + generation-tagged `Snapshot`.
  - `Inventory::Publisher` provider-facing wrapper plus the quarantined post-commit `ScopedRefresher::LegacyCoordinatorAdapter` old-coordinator projection.
  - `Routing::AttemptTargetKey`/`Selection`/`Rejection`/`Exclusion`/`QuotaDomainKey`/`BodyModelHintDecision` and the provider-neutral `Routing::ProviderOutcome`.
  - Fail-loud `Provider#speak`/`Provider#translate` base methods (no defaults; `REQUIRED_SIGNATURES` unchanged).
  - Additive exact-offering fleet execution (`Fleet::Protocol` `exact_offering_v1` marker, signed `execution_contract`/`offering_id`, registry-backed exact dispatch) alongside the unchanged protocol-v2 path.
  - Shared `'an SSOT v3 provider adapter'` conformance examples consumable by every provider PR.

  The contract adds no dependency on `legion-llm`, LegionIO, a database, ORM, or timer, and preserves every existing provider signature and protocol-v2 fleet behavior. Only the quarantined `ScopedRefresher` retains a direct `Legion::LLM::Inventory` reverse reference (removed in Phase 4).

## 0.6.16 - 2026-08-04

### Fixed
- **Interleaved streaming tool-call fragments are correlated by provider index.** `ToolCall` now carries the provider wire index, and `StreamAccumulator` maps continuation fragments back to the call opened at that index. Parallel calls no longer send every id-less fragment to the most recently opened call, which previously lost one call's arguments and contaminated another's.

## 0.6.15 - 2026-07-31

### Fixed
- **Remove dead `find_tool_call` method from StreamAccumulator.** Zero callers anywhere in lex-llm (confirmed via grep). The method referenced an undefined ivar `@latest_tool_call` (the actual ivar is `@latest_tool_call_id`) — it was broken dead code that could only ever return nil.
- **StreamAccumulator no longer drops tool_call opening fragments that arrive with `id: nil`.** When a tool_call chunk has no `id` but carries a `name` (indicating it's an opening fragment, not a continuation), the accumulator now generates a UUID and starts the call instead of silently dropping it via `append_tool_call_fragment`. This is defensive hardening — normal OpenAI-compatible streaming always assigns an id to the opening fragment, but non-conforming backends or edge cases could produce id-less openers. Existing id-based correlation is unchanged.

### Added
- **Contract specs asserting streaming `stop_reason` propagates through the StreamAccumulator.** Three regression specs encoding the accumulator's stop_reason behavior: single stop_reason captured from a chunk and propagated to the assembled Message, last-wins semantics when multiple chunks carry non-nil stop_reason, and nil-when-absent (no chunks carry stop_reason). This is the lex-llm half of the cross-gem streaming finish_reason fix — paired with lex-llm-vllm v0.3.15 (#16) which wires `stop_reason: canonical.stop_reason` through `to_legacy_chunk`.

## 0.6.14 - 2026-07-31

### Added
- **Connection#close tears down the underlying Faraday connection.** Previously `Connection` had no lifecycle method — persistent HTTP connections were never explicitly closed, causing CLOSE_WAIT socket accumulation when provider peers sent FIN (e.g. during daemon shutdown or provider restarts)
- **Provider#disconnect closes the connection and clears the reference.** Callers (legion-llm registry shutdown) can now explicitly tear down provider connections during graceful shutdown

## 0.6.13 - 2026-07-24

### Fixed
- **StreamAccumulator now captures `stop_reason` from provider done chunks.** Previously, the real `finish_reason` from the provider was silently discarded — the accumulator had no field for it, and the legacy `Message` class couldn't carry it. Downstream code always synthesized `:end_turn` regardless of what the provider actually said. Now `stop_reason` propagates through accumulator → Message → `normalize_response`.
- **Canonical::Chunk factory methods accept `stop_reason:` and `usage:` kwargs.** `text_delta`, `thinking_delta`, and `tool_call_delta` factories now pass through stop_reason and usage when present on the SSE event, enabling translators to propagate finish_reason on non-empty chunks without buffering.
- **Streaming handler iterates array results from `build_chunk`.** When a translator returns multiple chunks from a single SSE event (e.g. both thinking and content on the same delta), the handler now yields each one to the accumulator instead of expecting a single chunk. Prevents content loss at thinking/content boundaries.

## 0.6.12 - 2026-07-15

### Fixed
- **Strip leaked Gemma4 special tokens from response content.** Gemma4 models emit `<turn|>`, `<|turn>`, `<channel|>` as literal text when the serving engine fails to intercept them. `<turn|>` and `<channel|>` are end-of-turn signals — content is truncated at the first occurrence (everything after it is garbage). Other leaked tokens (`<|channel>`, `<|turn|>`) are stripped entirely. Prevents users seeing raw control tokens in responses and fixes cases where the leaked token caused downstream "no response returned" errors.
- **Remove `<|channel>` / `<channel|>` from `THINK_TAG_PAIRS`.** The channel delimiter is NOT always a thinking block — `<|channel>` is a generic channel marker and only becomes thinking when followed by `thought\n`. Having `<channel|>` as a close tag in `THINK_TAG_PAIRS` caused the extractor to consume ALL content before an orphaned `<channel|>` stop token as thinking, producing empty content (dead stop). Now handled only as a leaked stop token to truncate at.

## 0.6.11 - 2026-07-15

### Added
- **Gemma4 channel-based thinking tags** added to `ThinkingExtractor::THINK_TAG_PAIRS`. Gemma4 models use `<|channel>` / `<channel|>` as their reasoning block delimiters (equivalent to Qwen's `<think>`/`</think>`). If any serving engine (vLLM, SGLang, etc.) passes these tags through raw in the content field instead of pre-parsing them into `reasoning_content`, the extractor now strips them correctly.

## 0.6.10 - 2026-07-09

### Added
- `ThinkingConfig#resolved_budget` and `#resolved_effort` — cross-axis derivation so provider translators get whichever thinking axis they need (Anthropic `budget_tokens` vs OpenAI `effort`) even when the client supplied only the other. A client dialect supplies only one axis (Anthropic = budget only; OpenAI = effort only), so a single `EFFORT_BUDGET` map (SSOT) drives the conversion in both directions: effort -> budget is exact (`low` = 1024, `medium` = 8192, `high` = 16384), budget -> effort maps by band boundary. Explicitly-set values always win over derivation, and both accessors return `nil` when neither axis is configured. `to_h` stays faithful to what was actually set (no fabrication). This is the foundation for fixing thinking being silently dropped on cross-provider routes (e.g. a Claude budget request routed to OpenAI effort).

## 0.6.9 - 2026-07-05

### Added
- `StopReasonMapping` mixin (`legion/extensions/llm/stop_reason_mapping`) — a shared stop_reason vocabulary included by provider translators (and available to legion-llm, which depends on lex-llm). Keys are incoming provider wire strings, values are the canonical `stop_reason` symbol. Provider wire formats spell the same six canonical end-states differently (OpenAI/vLLM emit `tool_calls`, Anthropic `tool_use`; `stop`/`end_turn`/`eos` all mean the same thing), so the common vocabulary now lives in one place instead of being copy-pasted (and drifting) across provider gems.
  - `#stop_reason_map` — the common vocabulary, inherited by all.
  - `#stop_reason_map_additions` — returns `{}` in the base; a provider overrides it to ADD provider-specific strings (merged on top, additions win on collision). No guards needed.
  - `#stop_reason_lookup(key)` — merges additions over the map, coerces the key via `to_s`, returns the canonical symbol or `nil` (caller decides the default). To REPLACE the whole vocabulary, a provider overrides `#stop_reason_map`.

## 0.6.8 - 2026-07-03

### Changed
- Version bump to publish the `MeteringFlush` actor (0.6.5). Versions 0.6.5–0.6.7 tagged and created GitHub releases but never reached RubyGems: 0.6.5/0.6.6 failed `gem push` on a revoked API key, and 0.6.7 failed because the replacement API key was created with per-key MFA enabled (`gem push` prompted for an OTP a CI runner can't provide). The API key has been recreated without per-key MFA. Because the release workflow skips publishing when a version's tag/release already exists, each failed version must be superseded by a fresh one. No functional changes since 0.6.5.

## 0.6.7 - 2026-07-03

### Changed
- Version bump attempting to publish the `MeteringFlush` actor. Did not reach RubyGems — the replacement API key carried a per-key MFA requirement, so `gem push` demanded an OTP (superseded by 0.6.8). No functional changes.

## 0.6.6 - 2026-07-03

### Changed
- Version bump attempting to re-trigger the release pipeline. Did not publish to RubyGems — the `gem push` step failed on a revoked API key (superseded by 0.6.7). No functional changes.

## 0.6.5 - 2026-07-03

### Added
- **`MeteringFlush` actor drains the LLM metering spool back into RabbitMQ.** legion-llm's `Legion::LLM::Metering` spools metering events to `~/.legionio/data/spool/metering/events.jsonl` whenever transport is down at emit time. Nothing had been draining that spool since `lex-llm-gateway` was retired, so events (chat, embeddings, skills — all funnel through `Legion::LLM::Metering.emit`) accumulated indefinitely. This `Legion::Extensions::Actors::Every` actor ticks every 60s and calls `Legion::LLM::Metering.flush_spool`, which republishes each spooled event to the `llm.metering` exchange and truncates the file. It is a no-op while transport is unavailable, so it is safe to tick continuously. Runs on every node (not a singleton) because each node owns its own spool file and must drain it locally. References legion-llm by string (`'Legion::LLM::Metering'`) so lex-llm — the lower gem — avoids a circular dependency; the constant is resolved at tick time.

## 0.6.4 - 2026-06-30

### Fixed
- **Canonical Data structs now serialize correctly via MultiJson/Oj/::JSON** — all 10 `Data.define` canonical structs (`ToolCall`, `Message`, `ContentBlock`, `Chunk`, `Params`, `Request`, `Response`, `Thinking`, `ToolDefinition`, `Usage`) now implement `as_json` and `to_json`, delegating to their existing `#to_h` method. Without these callbacks, `MultiJson.dump` (and any JSON encoder) fell back to `obj.to_s` on canonical structs, producing the Ruby `#inspect` dump (e.g. `#<data Legion::Extensions::Llm::Canonical::ToolCall id="toolu_bdrk_...", ...>`) wherever a struct appeared inside a Hash/Array being serialized. This leaked into:
  - Client responses (`/v1/chat/completions`, `/v1/messages`, `/v1/responses`) — `tool_calls` in assistant message history appeared as inspect strings instead of structured JSON objects, breaking LangGraph/Freelens supervisors that expect structured routing decisions.
  - Ledger persistence (`llm_message_inference_requests.request_json`) — tool_calls stored as unparseable Ruby inspect strings, breaking history reconstruction on subsequent turns.
  - AMQP wire payloads — any consumer receiving a message containing canonical structs saw inspect strings instead of structured data.
  - Debug echo-request (`X-Legion-Debug: echo-request`) — canonical request snapshot contained inspect strings for any `tool_calls` in message history.

  The fix is structural: canonical structs now self-enforce correct JSON serialization at the architectural boundary (per Amendment A of the N×N routing design), so every downstream consumer — ledger, AMQP publisher, client translator, debug formatter — serializes correctly without needing to call `.to_h` explicitly.

## 0.6.3 - 2026-06-25

### Fixed
- `ContentBlock.from_hash` rescues `NoMethodError` when content arrays contain corrupted String elements (serialized `#inspect` output from prior storage bugs) — returns a text block instead of crashing with `undefined method 'transform_keys' for an instance of String`.
- `ContentBlock.from_hash` normalizes `output_text`/`input_text` types to `:text` via `TEXT_TYPE_ALIASES` so Responses API content blocks are recognized by `text?` and extracted by `Message#text`.
- `ContentBlock#to_s` returns clean text for all text-type blocks; `#inspect` returns a concise debug representation instead of the full 18-field Data.define dump.
- `Canonical::Message#to_s` delegates to `#text` to prevent Array#inspect leaking struct internals into string contexts.

## 0.6.2 - 2026-06-20

### Fixed
- Publish one `llm.registry` model-availability event per discovered model from the shared discovery/filter loop before whitelist/blacklist removes blocked models from routable offerings, preserving shadow-model visibility without polluting inventory.

## 0.6.1 - 2026-06-20

### Fixed
- Canonicalize routing capabilities in `lex-llm` itself: `embedding` is now the standard singular capability, `reasoning` aliases to `thinking`, and image/audio generation aliases collapse to the router vocabulary used by `Model::Info`, `ModelOffering`, and `CapabilityPolicy`.
- Standardize `enable_*` / `*_flag` capability overrides in the base provider contract, including provider-level, instance-level, and model-level extraction from shared settings handling.

## 0.6.0 - 2026-06-19

### Added
- **`Inventory::ScopedRefresher` mixin** — uniform `::Every` actor pattern for catalog writers.
  Each `lex-llm-*` gem includes this and supplies `scope_key` + `compute_lanes_for_scope`. The mixin
  handles write-then-delete-orphans, auth-failure cooldown circuit, and idempotent re-tick semantics.
  Requires legion-llm `>= 0.14.0` (`Inventory.write_lane` / `.delete_lane`).
- Standard `weight: 100` default in provider settings schema (feeds RANKING v2 `lane_weight`).
- `ScopedRefresher.compose_id(tier:, provider:, instance:, type:, model:, **)` — canonical 5-part
  lane id composer. All lane id composition must go through this method; never constructed inline.
- `:fleet` first-class tier in `Taxonomies::TIERS` enum.
- `Capabilities.normalize` normalization helper (PR #152 I1).

## 0.5.4 - 2026-06-17

### Fixed
- **Model policy enforced at dispatch (compliance)** — `model_whitelist` / `model_blacklist` were only applied when *listing* models (`discover_offerings`); inference dispatch never checked them, so a denied model could still be invoked directly. Added `enforce_model_allowed!`, called at every dispatch entry point (`complete` — which backs `chat`/`stream_chat` — plus `embed`, `moderate`, `paint`), raising the new `ModelNotAllowedError` *before* any provider API call. Fail-closed, no exceptions. `ModelNotAllowedError` is a distinct, non-HTTP error so callers can treat it as a terminal policy outcome (non-retryable, non-escalatable) rather than a provider failure.

## 0.5.3 - 2026-06-16

### Fixed
- **Streaming error classification** — Partial non-2xx streaming responses now raise status-specific errors (`UnauthorizedError`, `ForbiddenError`, `RateLimitError`, `ServiceUnavailableError`, etc.) instead of always raising `ServerError`. This preserves auth failures for downstream escalation and circuit handling.

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
