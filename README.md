# lex-llm

[![CI](https://github.com/LegionIO/lex-llm/actions/workflows/ci.yml/badge.svg)](https://github.com/LegionIO/lex-llm/actions/workflows/ci.yml)

Shared LegionIO framework for LLM provider extensions.

`lex-llm` is a standard Legion extension gem. It does not expose a standalone RubyLLM-compatible API, Rails integration, generators, rake tasks, or concrete providers. Its runtime contract is `Legion::Extensions::Llm`, which provider gems extend through nested namespaces such as `Legion::Extensions::Llm::Ollama`.

The routing principle is simple: provider is not the routing unit anymore. A concrete model offering is.

That lets Legion reason about one local Ollama instance with many models, multiple remote Ollama or vLLM instances, Bedrock accounts in different regions, direct frontier providers, and fleet workers on MacBooks, GPU servers, or cloud-side proxy nodes.

## What This Gem Owns

`lex-llm` provides provider-neutral primitives only. Provider-specific behavior belongs in provider gems.

This gem owns:

- `Legion::Extensions::Llm`, the Legion extension namespace used by autoloading and settings
- provider-neutral request, response, message, content, token, and tool objects
- schema bridging through `Legion::Extensions::Llm::Schema`
- model metadata and capability normalization
- routing structures such as `Legion::Extensions::Llm::Routing::ModelOffering`
- fleet lane key generation for shared RabbitMQ work lanes
- shared chat, embedding, moderation, image, transcription, streaming, and OpenAI-compatible adapter helpers
- shared runtime dependencies such as `legion-json`, `legion-settings`, and `legion-logging`

Concrete provider gems should depend on this gem and implement the provider-specific transport, authentication, model discovery, request translation, response translation, and health checks.

Expected provider gems include:

- `lex-llm-ollama`
- `lex-llm-vllm`
- `lex-llm-anthropic`
- `lex-llm-openai`
- `lex-llm-gemini`
- `lex-llm-mlx`
- `lex-llm-bedrock`
- `lex-llm-vertex`
- `lex-llm-azure-foundry`

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

Provider gems must use nested Legion extension namespaces so LegionIO autoloading can find them consistently.

Example for `lex-llm-ollama`:

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

- `offering_id`: stable identifier for the concrete offering; generated from provider, instance, usage type, and canonical alias when omitted
- `provider_family`: provider implementation family, such as `:ollama`, `:vllm`, `:bedrock`, `:anthropic`, or `:openai`
- `provider_instance`: concrete provider instance, account, node, region, or local runtime
- `instance_id`: compatibility alias for `provider_instance`
- `model_family`: provider-neutral family such as `:openai`, `:anthropic`, `:gemini`, `:qwen`, or `:llama`
- `transport`: `:local`, `:http`, `:rabbitmq`, `:sdk`, or another provider-supported transport
- `tier`: `:local`, `:private`, `:fleet`, `:cloud`, `:frontier`, or deployment-specific policy tier
- `model`: provider model name or normalized model alias
- `canonical_model_alias`: provider-neutral alias used by routers and shared fleet lane keys when a provider deployment hides the base model
- `usage_type`: `:inference` or `:embedding`
- `capabilities`: normalized feature flags such as `:chat`, `:tools`, `:json_schema`, `:vision`, `:thinking`, or `:embedding`
- `limits`: context window, output token limits, rate limits, concurrency limits, and provider-specific bounds
- `health`: readiness, latency, recent failures, and provider-specific health metadata
- `policy_tags`: routing and compliance tags such as `:internal_only`, `:phi_allowed`, or `:hipaa`
- `routing_metadata`: provider-neutral scheduling metadata for routers; persistence is intentionally out of scope
- `metadata`: extension-specific metadata; sensitive values are excluded from fleet eligibility fingerprints

Provider gems that still pass `instance_id`, or that store `model_family`, `canonical_model_alias`, or `alias` under `metadata`, remain compatible. `ModelOffering` lifts those values into first-class readers for routers.

`Legion::Extensions::Llm::Aliases.canonical_model_alias(model, provider)` provides shared alias normalization from `aliases.json`, with an explicit model string fallback.

## Offering Registry

`Legion::Extensions::Llm::Routing::OfferingRegistry` is an in-memory index for discovered or configured offerings. It does not persist state.

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

## Registry Events

`Legion::Extensions::Llm::Routing::RegistryEvent` builds dependency-light envelopes for future `llm.registry` publishing. It does not persist registry state or publish messages by itself.

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
# => {
#      event_id: "...",
#      event_type: :offering_available,
#      occurred_at: "2026-04-28T14:30:15.123456Z",
#      offering: { ... },
#      runtime: { host_id: "macbook-m4-max", process: { pid: 12345 } },
#      capacity: { concurrency: 4, queued: 0 },
#      health: { ready: true, latency_ms: 180 },
#      lane: "llm.fleet.inference.qwen3-6-27b-q4-k-m.ctx32768",
#      metadata: { observed_by: :lex_llm_ollama }
#    }
```

Supported event types are `:offering_available`, `:offering_unavailable`, `:offering_degraded`, and `:offering_heartbeat`. Event offerings are derived from `ModelOffering#to_h`, with sensitive offering fields removed. Optional `runtime`, `capacity`, `health`, `lane`, and `metadata` values are intended for non-secret operational context and reject sensitive keys such as credentials, tokens, secrets, URLs, endpoint paths, prompts, and reply queues.

## Fleet Lanes

Fleet routing uses shared work lanes derived from model offerings. A lane describes the work required, not the worker that happens to do it.

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

The intent is that any eligible worker can bind to the same lane:

- local MacBook workers
- GPU servers in a datacenter
- vLLM workers
- Ollama workers
- cloud-side LegionIO workers near Bedrock, Vertex, Azure, or another provider

Busy endpoint workers should not reject/requeue in a hot loop. Endpoint fleet workers can use pull-style scheduling, while server-class workers can use normal consumers with prefetch and consumer priority.

## Default Fleet Settings

`Legion::Extensions::Llm.default_settings` provides defaults that provider extensions inherit and override:

```ruby
Legion::Extensions::Llm.default_settings
# => {
#      fleet: {
#        enabled: false,
#        scheduler: :basic_get,
#        consumer_priority: 0,
#        queue_expires_ms: 60_000,
#        message_ttl_ms: 120_000,
#        queue_max_length: 100,
#        delivery_limit: 3,
#        consumer_ack_timeout_ms: 300_000,
#        endpoint: {
#          enabled: false,
#          empty_lane_backoff_ms: 250,
#          idle_backoff_ms: 1_000,
#          max_consecutive_pulls_per_lane: 0,
#          accept_when: []
#        }
#      }
#    }
```

The defaults are conservative:

- fleet participation is off unless configured
- endpoint fleet mode is separately disabled by default
- queue and message TTLs are bounded
- pull scheduling is the default for endpoint-style workers
- provider gems can override defaults through `Legion::Settings`

Provider gems can build a complete provider settings hash without duplicating merge logic:

```ruby
Legion::Extensions::Llm.provider_settings(
  family: :ollama,
  instance: {
    base_url: 'http://localhost:11434',
    fleet: { enabled: true, consumer_priority: 10 }
  }
)
```

## Provider Extension Contract

A provider gem should use `lex-llm` for shared behavior and implement only the provider-specific pieces.

At minimum, a provider extension should define:

- `Legion::Extensions::Llm::<Provider>`
- provider default settings
- model discovery or a static model offering registry
- provider request translation
- provider response translation
- health and readiness checks
- embedding support separately from inference support when the provider exposes both

Provider extensions should avoid duplicating shared classes, schema logic, fleet lane construction, JSON handling, or common request/response objects.

Canonical provider calls are keyword-based:

```ruby
provider.chat(messages:, model:, tools: [], temperature: nil, params: {}, headers: {}, schema: nil, thinking: nil)
provider.stream_chat(messages:, model:, tools: [], temperature: nil, params: {}, headers: {}, schema: nil, thinking: nil) { |chunk| ... }
provider.embed(text:, model:, dimensions: nil, params: {}, headers: {})
provider.image(prompt:, model:, size:, with: nil, mask: nil, params: {})
provider.count_tokens(messages:, model:, params: {})
provider.health(live: false)
provider.discover_offerings(live: false, **filters)
```

Provider responses should normalize through the shared response objects before they reach callers. Visible assistant text and provider reasoning are separate values: provider-specific thinking fields, OpenAI-compatible `reasoning_content`, and literal `<think>...</think>` text are removed from caller-visible content and preserved as thinking metadata when present.

Fleet envelopes also live here. `FleetRequest`, `FleetResponse`, and `FleetError` are protocol-v2 transport messages with `operation`, `request_id`, `correlation_id`, `idempotency_key`, `message_context`, and signed-token fields. Provider gems should consume and publish these shared envelopes instead of defining local fleet message shapes.

All providers inherit `#readiness(live: false)`, which returns configured state, provider locality, API base, endpoint helpers, and non-live health metadata without probing remote services. Providers with a cheap health endpoint can pass `live: true` to include that endpoint response. OpenAI-compatible providers also inherit shared model-list parsing that maps discovered models into normalized capabilities and modalities for Legion routing.

## Schema Status

`lex-llm` still depends on `ruby_llm-schema` because the current schema bridge exposes:

```ruby
Legion::Extensions::Llm::Schema
```

as:

```ruby
RubyLLM::Schema
```

That dependency should stay until LegionIO owns or replaces the schema layer directly.

## Development

Install dependencies:

```bash
bundle install
```

Run lint:

```bash
bundle exec rubocop -A
```

Run the full test suite:

```bash
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
```

`Gemfile.lock` is intentionally not committed for this repo.

## Attribution

`lex-llm` began as a LegionIO fork of RubyLLM. RubyLLM remains credited under the MIT license in `LICENSE`.
