# lex-llm

[![CI](https://github.com/LegionIO/lex-llm/actions/workflows/ci.yml/badge.svg)](https://github.com/LegionIO/lex-llm/actions/workflows/ci.yml)

Base provider framework for all LegionIO LLM provider extensions.

`lex-llm` is a standard Legion extension gem that provides provider-neutral primitives for LLM integration. It does not include concrete provider implementations -- those live in `lex-llm-*` gems (e.g. `lex-llm-ollama`, `lex-llm-openai`, `lex-llm-bedrock`). The routing unit is a **model offering**, not a provider, enabling Legion to reason about any combination of local instances, remote servers, cloud providers, and fleet workers.

---

## Quick Index

| Topic | Section |
|-------|---------|
| Install & depend | [Install](#install) |
| Extension namespace | [Namespace](#namespace) |
| Core classes & files | [Class Index](#class-index) |
| Model offerings (routing) | [Model Offerings](#model-offerings) |
| In-memory offering registry | [Offering Registry](#offering-registry) |
| Fleet lanes & work routing | [Fleet Lanes](#fleet-lanes) |
| Fleet protocol v2 | [Fleet Protocol](#fleet-protocol) |
| Registry events | [Registry Events](#registry-events) |
| Provider contract | [Provider Extension Contract](#provider-extension-contract) |
| Streaming & accumulator | [Streaming](#streaming) |
| Credential discovery | [Credential Sources](#credential-sources) |
| Auto-registration | [Auto Registration](#auto-registration) |
| Provider settings | [Provider Settings](#provider-settings) |
| Schema & tools | [Schema & Tools](#schema--tools) |
| Response objects | [Response Objects](#response-objects) |
| Configuration | [Configuration](#configuration) |
| Running tests | [Development](#development) |

---

## Install

```ruby
gem 'lex-llm'
```

Provider extensions should declare `lex-llm` as a gemspec dependency:

```ruby
spec.add_dependency 'lex-llm', '>= 0.4.3'
```

For local development across LegionIO repos, prefer a local path override in the app or test `Gemfile`, not a permanent git dependency in the gemspec.

## Namespace

Load the extension through the Legion namespace:

```ruby
require 'legion/extensions/llm'
```

All classes live under `Legion::Extensions::Llm`. Provider gems must use nested Legion extension namespaces so LegionIO autoloading finds them consistently:

```ruby
require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Ollama
        def self.default_settings
          Legion::Extensions::Llm.provider_settings(
            family: :ollama,
            instance: { base_url: 'http://localhost:11434' }
          )
        end
      end
    end
  end
end
```

---

## Class Index

### Core
| Class | File | Purpose |
|-------|------|---------|
| `Provider` | `lib/.../provider.rb` | Base class for all provider adapters. Includes `Legion::Cache::Helper` and `Legion::Logging::Helper`. Mixin entry point for credentials, model caching, and model whitelist/blacklist. |
| `Provider::OpenAICompatible` | `lib/.../provider/open_ai_compatible.rb` | Shared adapter for OpenAI-compatible servers (vLLM, Ollama, MLX, local proxies). Handles request/response translation, streaming, tool calls, embedding, image, transcription, and thinking extraction. |
| `ProviderContract` | `lib/.../provider_contract.rb` | Defines the canonical provider interface: `chat`, `stream_chat`, `embed`, `image`, `count_tokens`, `health`, `discover_offerings`. Raises `UnsupportedCapability` for unimplemented methods. |
| `Configuration` | `lib/.../configuration.rb` | Hash-backed provider config wrapper; normalizes instance-level and fleet-level settings. |
| `ProviderSettings` | `lib/.../provider_settings.rb` | Builds complete provider settings from `family`, `instance`, and nested fleet settings. Includes `infer_tier_from_endpoint(url)` to detect `:local` vs `:direct`. |

### Requests & Data Types
| Class | File | Purpose |
|-------|------|---------|
| `Message` | `lib/.../message.rb` | Structured message (role, content, tool calls, attachments, thinking). |
| `Content` | `lib/.../content.rb` | Content part (text, image, file, tool result) with MIME type support. |
| `Tool` | `lib/.../tool.rb` | Tool definition (name, description, parameters, strict mode). |
| `ToolCall` | `lib/.../tool_call.rb` | Tool call result (id, function name, arguments, result). |
| `Attachment` | `lib/.../attachment.rb` | File attachment with content, filename, and MIME type. |
| `Chunk` | `lib/.../chunk.rb` | Streaming chunk wrapper (content delta, reasoning, tool call delta, usage). |
| `Context` | `lib/.../context.rb` | Conversation context builder; normalizes history and strips thinking. |
| `Thinking` | `lib/.../thinking.rb` | Thinking/reasoning metadata extracted from provider output. |
| `MimeType` | `lib/.../mime_type.rb` | MIME type utilities for image and file content. |

### Model & Routing
| Class | File | Purpose |
|-------|------|---------|
| `Model::Info` | `lib/.../model/info.rb` | Immutable `Data.define` struct: `instance`, `provider_family`, `provider_model`, `parameter_count`, `quantization`, `size_bytes`, `modalities_input/output`, `context_window`, `max_output_tokens`, `pricing`, `capabilities`, `created_at`, `knowledge_cutoff`. Factory: `Model::Info.from_hash` for legacy hash compatibility. |
| `Model::Modalities` | `lib/.../model/modalities.rb` | Canonical modality symbols and helpers. |
| `Model::Pricing` | `lib/.../model/pricing.rb` | Pricing data struct with `PricingCategory` and `PricingTier`. |
| `Models` | `lib/.../models.rb` | Shared model listing and metadata normalization. Uses `Call::Registry` with namespace-scanning fallback. |
| `Routing::ModelOffering` | `lib/.../routing/model_offering.rb` | Concrete offering: one model on one provider instance. Routing/filtering/health/policy unit. See [Model Offerings](#model-offerings). |
| `Routing::OfferingRegistry` | `lib/.../routing/offering_registry.rb` | In-memory index for offerings. See [Offering Registry](#offering-registry). |
| `Routing::LaneKey` | `lib/.../routing/lane_key.rb` | Derives fleet lane key strings from offerings. |
| `Aliases` | `lib/.../aliases.rb` | Canonical model alias normalization from `aliases.json`. |
| `Routing::RegistryEvent` | `lib/.../routing/registry_event.rb` | Envelope builder for registry availability events. |

### Responses
| Class | File | Purpose |
|-------|------|---------|
| `Responses::ChatResponse` | `lib/.../responses/chat_response.rb` | Normalized chat response: message, usage, thinking, finish_reason. |
| `Responses::EmbeddingResponse` | `lib/.../responses/embedding_response.rb` | Normalized embedding response: vectors, usage, model. |
| `Responses::StreamChunk` | `lib/.../responses/stream_chunk.rb` | Normalized stream chunk with delta fields and metadata. |
| `Responses::ThinkingExtractor` | `lib/.../responses/thinking_extractor.rb` | Extracts thinking/reasoning from provider output (reasoning_content, `</think>` tags, untagged preambles). |

### Streaming
| Class | File | Purpose |
|-------|------|---------|
| `Streaming` | `lib/.../streaming.rb` | Streaming framework: Faraday middleware, chunk parsing, retry on status 500, thinking extraction, error handling. Handles both Net::HTTP and Typhoeus adapters. |
| `StreamAccumulator` | `lib/.../stream_accumulator.rb` | Accumulates streaming deltas into complete messages; assembles partial tool-call arguments, separates thinking from content, builds tool call arrays. |

### Fleet (Protocol v2)
| Class | File | Purpose |
|-------|------|---------|
| `Fleet::Protocol` | `lib/.../fleet/protocol.rb` | Protocol v2 constants, field names, and versioning. |
| `Fleet::EnvelopeValidation` | `lib/.../fleet/envelope_validation.rb` | Validates v2 envelopes; rejects legacy fields. |
| `Fleet::TokenValidator` | `lib/.../fleet/token_validator.rb` | Validates JWT replay tokens with issuer verification and hash-based claims. |
| `Fleet::TokenError` | `lib/.../fleet/token_error.rb` | Token validation error types. |
| `Fleet::Settings` | `lib/.../fleet/settings.rb` | Default fleet settings builder (consumer, auth, endpoint). |
| `Fleet::ProviderResponder` | `lib/.../fleet/provider_responder.rb` | Responder-side execution: receives fleet requests, validates tokens, dispatches to provider, publishes responses. |
| `Fleet::WorkerExecution` | `lib/.../fleet/worker_execution.rb` | Worker-side execution: binds to lanes, pulls/consumes messages, manages backpressure. |
| `Fleet::DefaultExchangeReply` | `lib/.../fleet/default_exchange_reply.rb` | Publishes replies via AMQP default exchange with publisher confirms. |
| `Fleet::PublishSafety` | `lib/.../fleet/publish_safety.rb` | Guards against infinite requeues on publish failure. |
| `Transport::Messages::FleetRequest` | `lib/.../transport/messages/fleet_request.rb` | Encrypted fleet request envelope (v2). |
| `Transport::Messages::FleetResponse` | `lib/.../transport/messages/fleet_response.rb` | Encrypted fleet response envelope (v2). |
| `Transport::Messages::FleetError` | `lib/.../transport/messages/fleet_error.rb` | Encrypted fleet error envelope (v2). |
| `Transport::Exchanges::Fleet` | `lib/.../transport/exchanges/fleet.rb` | Fleet exchange declarations. |
| `Transport::Exchanges::LlmRegistry` | `lib/.../transport/exchanges/llm_registry.rb` | Registry exchange for offering availability events. |
| `Transport::FleetLane` | `lib/.../transport/fleet_lane.rb` | Fleet lane declaration and binding. |
| `RegistryPublisher` | `lib/.../registry_publisher.rb` | Publishes registry events to `llm.registry` exchange. |
| `RegistryEventBuilder` | `lib/.../registry_event_builder.rb` | Builds sanitized registry event messages. |

### Credentials & Discovery
| Class | File | Purpose |
|-------|------|---------|
| `CredentialSources` | `lib/.../credential_sources.rb` | Read-only probes: env vars, `~/.claude/settings.json`, `~/.codex/auth.json`, `Legion::Settings`, socket/HTTP probes. SHA-256 credential dedup via `credential_fingerprint`. Includes `source_tag(type, location, key)` for provenance. Probing gated behind `extensions.llm.security.credential_source_probing`. |
| `AutoRegistration` | `lib/.../auto_registration.rb` | Mixin for provider self-registration into `Call::Registry`. Discovers instances, builds offerings, handles rediscovery. Pure discovery -- no upward registry mutation. |

### Capabilities
| Class | File | Purpose |
|-------|------|---------|
| `Chat` | `lib/.../chat.rb` | Shared chat request builder and parameter normalization. |
| `Embedding` | `lib/.../embedding.rb` | Embedding request builder. |
| `Image` | `lib/.../image.rb` | Image generation request builder. |
| `Moderation` | `lib/.../moderation.rb` | Moderation request builder. |
| `Tokens` | `lib/.../tokens.rb` | Token counting request builder. |
| `Transcription` | `lib/.../transcription.rb` | Audio transcription request builder. |
| `Agent` | `lib/.../agent.rb` | Agent-specific context and parameter helpers. |

### Connection
| Class | File | Purpose |
|-------|------|---------|
| `Connection` | `lib/.../connection.rb` | Faraday connection builder with `:typhoeus` adapter preference, bearer token redaction in logs, middleware stack, and error handling. |

### Misc
| Class | File | Purpose |
|-------|------|---------|
| `Schema` | `lib/.../schema.rb` | Bridge to `ruby_llm-schema` for JSON schema tool definitions. |
| `Error` | `lib/.../error.rb` | Base error class for lex-llm. |
| `Errors::UnsupportedCapability` | `lib/.../errors/unsupported_capability.rb` | Raised when a provider lacks a requested capability. |
| `Utils` | `lib/.../utils.rb` | Shared utility methods. |
| `VERSION` | `lib/.../version.rb` | Current gem version (`0.4.18`). |

---

## Model Offerings

A model offering describes one concrete model made available by one provider instance. It is the base unit for routing, filtering, fleet lane creation, health, policy, and cost decisions.

```ruby
offering = Legion::Extensions::Llm::Routing::ModelOffering.new(
  offering_id: 'ollama:macbook_m4_max:inference:qwen3-6-27b-q4-k-m',
  provider_family: :ollama,
  provider_instance: :macbook_m4_max,
  transport: :local,
  tier: :local,
  model: 'qwen3.6:27b-q4_K_M',
  canonical_model_alias: 'qwen3.6:27b-q4_K_M',
  model_family: :qwen,
  usage_type: :inference,
  capabilities: %i[chat tools vision thinking],
  limits: {
    context_window: 32_768,
    max_output_tokens: 8_192
  },
  health: {
    ready: true,
    latency_ms: 180
  },
  policy_tags: %i[internal_only phi_allowed],
  routing_metadata: {
    region: :local,
    accelerator: :metal
  },
  metadata: {
    enabled: true,
    eligibility: {
      ac_power: true
    }
  }
)

offering.eligible_for?(
  usage_type: :inference,
  required_capabilities: %i[tools],
  min_context_window: 16_000,
  policy_tags: %i[internal_only]
)
# => true
```

Common offering fields:

- `offering_id`: stable identifier; generated from provider, instance, usage type, and canonical alias when omitted
- `provider_family`: `:ollama`, `:vllm`, `:bedrock`, `:anthropic`, `:openai`, etc.
- `provider_instance`: concrete provider instance, account, node, region, or local runtime
- `instance_id`: compatibility alias for `provider_instance`
- `model_family`: provider-neutral family such as `:openai`, `:anthropic`, `:qwen`, `:llama`
- `transport`: `:local`, `:http`, `:rabbitmq`, `:sdk`
- `tier`: `:local`, `:private`, `:fleet`, `:cloud`, `:frontier`
- `model`: provider model name or normalized alias
- `canonical_model_alias`: provider-neutral alias for routers and fleet lanes
- `usage_type`: `:inference` or `:embedding`
- `capabilities`: `:chat`, `:tools`, `:json_schema`, `:vision`, `:thinking`, `:embedding`, `:function_calling`
- `limits`: context window, output token limits, rate limits, concurrency
- `health`: readiness, latency, recent failures
- `policy_tags`: `:internal_only`, `:phi_allowed`, `:hipaa`
- `routing_metadata`: scheduling metadata for routers
- `metadata`: extension metadata; sensitive values excluded from fleet fingerprints

`Legion::Extensions::Llm::Aliases.canonical_model_alias(model, provider)` normalizes aliases from `aliases.json`.

## Offering Registry

`Legion::Extensions::Llm::Routing::OfferingRegistry` is an in-memory index.

```ruby
registry = Legion::Extensions::Llm::Routing::OfferingRegistry.new
registry.register(offering)

registry.find(offering.offering_id)
registry.find_by_model_alias('qwen3.6:27b-q4_K_M')
registry.filter(
  provider_family: :ollama,
  provider_instance: :macbook_m4_max,
  model_family: :qwen,
  capability: :tools
)
```

## Fleet Lanes

Fleet routing uses shared work lanes derived from offerings. A lane describes the work, not the worker:

```ruby
offering.lane_key
# => "llm.fleet.inference.qwen3-6-27b-q4-k-m.ctx32768"
```

Embedding lanes omit context size:

```ruby
Legion::Extensions::Llm::Routing::ModelOffering.new(
  provider_family: :ollama,
  instance_id: :gpu_embed_01,
  transport: :rabbitmq,
  model: 'nomic-embed-text',
  usage_type: :embedding,
  capabilities: %i[embedding]
).lane_key
# => "llm.fleet.embed.nomic-embed-text"
```

Any eligible worker can bind to the same lane: local MacBooks, GPU servers, vLLM workers, Ollama workers, or cloud-side LegionIO workers near Bedrock/Vertex/Azure.

## Fleet Protocol

Fleet communication uses protocol v2 envelopes with strict validation:

- `FleetRequest`: encrypted request envelope with `operation`, `request_id`, `correlation_id`, `idempotency_key`, `message_context`, and signed JWT replay token
- `FleetResponse`: encrypted response envelope with provider output
- `FleetError`: encrypted error envelope with typed error metadata

When `fleet.compliance.encrypt_fleet` is true (default), all envelopes are encrypted via `Legion::Crypt`. JWT replay tokens validate the `issuer` claim and use hash-based claim validation (no raw PHI in base64 payloads).

`Fleet::ProviderResponder` handles the responder side: token validation, idempotency, provider dispatch, response publishing. `Fleet::WorkerExecution` handles the worker side: lane binding, message consumption, backpressure.

Default fleet settings via `Legion::Extensions::Llm.default_settings` -- fleet and endpoint modes are disabled by default:

```ruby
{
  fleet: {
    enabled: false,
    scheduler: :basic_get,
    consumer_priority: 0,
    queue_expires_ms: 60_000,
    message_ttl_ms: 120_000,
    queue_max_length: 100,
    delivery_limit: 3,
    consumer_ack_timeout_ms: 300_000,
    endpoint: {
      enabled: false,
      empty_lane_backoff_ms: 250,
      idle_backoff_ms: 1_000,
      max_consecutive_pulls_per_lane: 0,
      accept_when: []
    }
  }
}
```

## Registry Events

`Legion::Extensions::Llm::Routing::RegistryEvent` builds envelopes for `llm.registry` publishing.

```ruby
event = Legion::Extensions::Llm::Routing::RegistryEvent.available(
  offering,
  runtime: { host_id: 'macbook-m4-max', process: { pid: 12_345 } },
  capacity: { concurrency: 4, queued: 0 },
  health: { ready: true, latency_ms: 180 },
  lane: offering.lane_key,
  metadata: { observed_by: :lex_llm_ollama }
)

event.to_h
# => { event_id: "...", event_type: :offering_available, offering: { ... }, ... }
```

Supported types: `:offering_available`, `:offering_unavailable`, `:offering_degraded`, `:offering_heartbeat`. Sensitive keys (credentials, tokens, secrets, URLs, prompts) are rejected during sanitization.

Publishing is handled by `RegistryPublisher` (parameterized by `provider_family`) through the `llm.registry` exchange.

## Credential Sources

`CredentialSources` provides read-only credential discovery:

```ruby
Legion::Extensions::Llm::CredentialSources.discover_credentials(
  family: :openai,
  setting_key: 'OPENAI_API_KEY'
)
```

Probes env vars, `~/.claude/settings.json`, `~/.codex/auth.json`, `Legion::Settings`, and optional socket/HTTP endpoints. Credentials are deduplicated via `credential_fingerprint` (first 8 chars of SHA-256). Probing is gated behind `extensions.llm.security.credential_source_probing`.

Each source gets a provenance tag: `CredentialSources.source_tag(type, location, key)`.

## Auto Registration

`AutoRegistration` mixin enables providers to self-discover instances and register offerings into `Call::Registry`:

```ruby
class MyProvider < Legion::Extensions::Llm::Provider
  extend Legion::Extensions::Llm::AutoRegistration
end

MyProvider.rediscover!  # Re-probe all instances
```

Discovers instances from settings, builds model offerings via `discover_offerings`, and registers them. Passes tier and capabilities metadata to the registry.

## Streaming

`Streaming` provides the streaming framework for OpenAI-compatible SSE responses:

- Faraday middleware handles chunk parsing, thinking extraction, and error handling
- `StreamAccumulator` accumulates deltas into complete messages with tool-call assembly
- Retries on HTTP 500 with partial body preservation
- Handles both Net::HTTP and Typhoeus adapters (Typhoeus chunks arrive with nil/0 status during streaming)
- Provider thinking (`</think>` tags, `reasoning_content`) is stripped from caller-visible content

```ruby
provider.stream_chat(messages:, model:, tools: []) do |chunk|
  # chunk is a Chunk or StreamChunk with content_delta, reasoning_delta, tool_call_delta
end
```

## Schema & Tools

`Legion::Extensions::Llm::Schema` bridges `ruby_llm-schema` for JSON schema tool definitions. Tools are defined as:

```ruby
Legion::Extensions::Llm::Tool.new(
  name: 'search',
  description: 'Search the knowledge base',
  parameters: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'Search query' }
    },
    required: %w[query]
  }
)
```

## Response Objects

All provider responses should normalize through the shared response objects:

- `Responses::ChatResponse` -- chat completions with message, usage, thinking, finish_reason
- `Responses::EmbeddingResponse` -- vectors, usage, model
- `Responses::StreamChunk` -- streaming deltas
- `Responses::ThinkingExtractor` -- extracts thinking from multiple formats (reasoning_content, `</think>` tags, untagged preambles)

Provider-specific thinking is always separated from caller-visible content.

---

## Provider Extension Contract

A provider gem uses `lex-llm` for shared behavior and implements only provider-specific transport, authentication, model discovery, and translation.

At minimum, a provider extension defines:

- `Legion::Extensions::Llm::<Provider>` namespace
- Provider default settings
- Model discovery or static model offering registry
- Provider request/response translation
- Health and readiness checks

Canonical provider calls (all keyword-based):

```ruby
provider.chat(messages:, model:, tools: [], temperature: nil, params: {}, headers: {}, schema: nil, thinking: nil)
provider.stream_chat(messages:, model:, tools: [], temperature: nil, params: {}, headers: {}, schema: nil, thinking: nil) { |chunk| ... }
provider.embed(text:, model:, dimensions: nil, params: {}, headers: {})
provider.image(prompt:, model:, size:, with: nil, mask: nil, params: {})
provider.count_tokens(messages:, model:, params: {})
provider.health(live: false)
provider.discover_offerings(live: false, **filters)
```

Inherited from `Provider`:

- `#readiness(live: false)` -- configured state, locality, base URL, non-live health metadata
- `#model_detail(model_name)` -- cache-backed lookup (24h TTL; nil results not cached)
- `#model_allowed?(model_name)` -- whitelist/blacklist check
- `#discover_offerings(live: false)` -- cached live discovery when `live: false`, probes endpoints when `true`
- `#offering_transport` / `#offering_tier` -- instance methods with class-level `default_transport`/`default_tier` overrides
- `#runtime_provider_setting(key)` -- fallback to `Legion::Settings` for model whitelist/blacklist

Inherited from `Provider::OpenAICompatible`:

- Full OpenAI-compatible API translation
- Model list parsing with capability/modality normalization
- Streaming with thinking extraction
- Embedding, image, transcription, moderation support
- `fetch_model_detail` override hook for live API model metadata

## Configuration

Provider settings are built with `Legion::Extensions::Llm.provider_settings`:

```ruby
Legion::Extensions::Llm.provider_settings(
  family: :ollama,
  instance: {
    base_url: 'http://localhost:11434',
    fleet: { enabled: true, consumer_priority: 10 }
  }
)
```

`ProviderSettings.infer_tier_from_endpoint(url)` returns `:local` for localhost/loopback, `:direct` for all other hosts.

Key settings paths:

- `extensions.llm.fleet` -- fleet participation and behavior
- `extensions.llm.fleet.endpoint` -- endpoint-style worker configuration
- `extensions.llm.fleet.compliance.encrypt_fleet` -- encrypt fleet envelopes (default true)
- `extensions.llm.fleet.auth.verify_issuer` -- validate JWT issuer (default true)
- `extensions.llm.security.credential_source_probing` -- gate credential probing (default true)
- `extensions.llm.model_whitelist` / `model_blacklist` -- provider-level model filters
- `extensions.llm.<family>.instance.<name>.model_whitelist` -- per-instance override

---

## Provider Dependencies

| Extension | Depends on |
|-----------|-----------|
| `Provider` | `Legion::Cache::Helper`, `Legion::Logging::Helper`, `Legion::Settings`, `Legion::JSON` |
| `Streaming` | Faraday (`:typhoeus` or `:net_http`), Typhoeus |
| `Connection` | Faraday, Faraday::Typhoeus |
| `CredentialSources` | `Legion::Settings` (for Legion-settings probes) |
| `Fleet::*` | `Legion::Crypt` (when `encrypt_fleet` is true), `Legion::Transport` (AMQP via bunny) |
| `Schema` | `ruby_llm-schema` |

Runtime gem dependencies: `legion-json`, `legion-settings`, `legion-logging`, `legion-cache`, `faraday`, `faraday-typhoeus`, `ruby_llm-schema`.

## Development

Install dependencies:

```bash
bundle install
```

Run the full test suite:

```bash
bundle exec rspec
```

Run lint and auto-correct:

```bash
bundle exec rubocop -A
```

`Gemfile.lock` is intentionally not committed for this repo.

### Testing Rules

- Do NOT mock `Legion::Settings`, `Legion::Logging`, `Legion::JSON`, or `Legion::Cache` -- require the real gems
- `Legion::Cache.setup` activates the Memory adapter in test (no Redis needed)
- `Faraday::ConnectionFailed` is rescued in `discover_offerings` with a concise log
- `bundle exec rspec && bundle exec rubocop -A` is the gate before committing

## Key Patterns

- `Provider` includes `Legion::Cache::Helper` -- use `cache_get`/`cache_set` directly
- `model_detail(model_name)` -- cache-backed lookup (cache_get -> fetch_model_detail -> cache_set if non-nil)
- `fetch_model_detail` -- override in subclass for live API calls; return `{ context_window: N }` or nil
- `model_detail_cache_key` includes credential fingerprint for non-local providers
- `model_whitelist`/`model_blacklist` -- checks instance config first, then provider settings
- `discover_offerings` filters via `model_allowed?` and rescues `Faraday::ConnectionFailed`
- Faraday response logger: `errors: false` -- never dump raw stacktraces from HTTP failures
- `CredentialSources.source_tag(type, location, key)` -- provenance tag for discovered credentials
- `CredentialSources.credential_fingerprint(value)` -- first 8 chars of SHA-256

## Attribution

`lex-llm` began as a LegionIO fork of RubyLLM. RubyLLM remains credited under the MIT license in `LICENSE`.
