# lex-llm

[![CI](https://github.com/LegionIO/lex-llm/actions/workflows/ci.yml/badge.svg)](https://github.com/LegionIO/lex-llm/actions/workflows/ci.yml)

Shared LegionIO framework for LLM provider extensions.

`lex-llm` is the provider-neutral base layer for LegionIO LLM work. It defines the common Ruby API, schema bridge, model metadata, routing structures, request/response helpers, streaming helpers, and Legion extension namespace that concrete provider gems build on.

The routing principle is simple: provider is not the routing unit anymore. A concrete model offering is.

That means Legion can reason about:

- one local Ollama instance with many models
- multiple remote Ollama or vLLM instances
- several Bedrock accounts or regions exposing overlapping Anthropic models
- direct frontier providers such as OpenAI or Anthropic
- fleet workers on MacBooks, GPU servers, or cloud-side proxy nodes

## What This Gem Owns

`lex-llm` provides shared primitives only. Provider-specific behavior belongs in provider gems.

This gem owns:

- `LexLLM`, the shared Ruby API and base provider framework
- `Legion::Extensions::Llm`, the Legion extension namespace used by autoloading and settings
- provider-neutral model metadata and capability normalization
- routing structures such as `LexLLM::Routing::ModelOffering`
- fleet lane key generation for shared RabbitMQ work lanes
- common chat, embedding, tool, streaming, ActiveRecord, and schema helpers
- shared runtime dependencies such as `legion-json`, `legion-settings`, and `legion-logging`

Concrete provider gems should depend on this gem and implement the provider-specific transport, authentication, model discovery, request translation, and response translation.

Expected provider gems include:

- `lex-llm-ollama`
- `lex-llm-vllm`
- `lex-llm-anthropic`
- `lex-llm-openai`
- `lex-llm-gemini`
- `lex-llm-mlx`
- `lex-llm-bedrock`
- `lex-llm-vertex`
- `lex-llm-azure`

## Install

```ruby
gem 'lex-llm'
```

Provider extensions should declare `lex-llm` as a gemspec dependency:

```ruby
spec.add_dependency 'lex-llm', '>= 0.1.0'
```

For local development across LegionIO repos, prefer a local path override in the app or test `Gemfile`, not a permanent git dependency in the gemspec.

## Namespaces

This gem exposes two runtime namespaces:

- `LexLLM` for shared Ruby classes, provider primitives, schemas, and helpers
- `Legion::Extensions::Llm` for LegionIO extension loading and default settings

Provider gems must use nested Legion extension namespaces so LegionIO autoloading can find them consistently.

Example for `lex-llm-ollama`:

```ruby
require 'legion/extensions/llm/ollama'

module Legion
  module Extensions
    module Llm
      module Ollama
        def self.default_settings
          Legion::Extensions::Llm.default_settings.merge(
            provider_family: :ollama
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
offering = LexLLM::Routing::ModelOffering.new(
  provider_family: :ollama,
  instance_id: :macbook_m4_max,
  transport: :local,
  tier: :local,
  model: 'qwen3.6:27b-q4_K_M',
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

- `provider_family`: provider implementation family, such as `:ollama`, `:vllm`, `:bedrock`, `:anthropic`, or `:openai`
- `instance_id`: concrete provider instance, account, node, region, or local runtime
- `transport`: `:local`, `:http`, `:rabbitmq`, `:sdk`, or another provider-supported transport
- `tier`: `:local`, `:private`, `:fleet`, `:cloud`, `:frontier`, or deployment-specific policy tier
- `model`: provider model name or normalized model alias
- `usage_type`: `:inference` or `:embedding`
- `capabilities`: normalized feature flags such as `:chat`, `:tools`, `:json_schema`, `:vision`, `:thinking`, or `:embedding`
- `limits`: context window, output token limits, rate limits, concurrency limits, and provider-specific bounds
- `health`: readiness, latency, recent failures, and provider-specific health metadata
- `policy_tags`: routing and compliance tags such as `:internal_only`, `:phi_allowed`, or `:hipaa`
- `metadata`: extension-specific metadata; sensitive values are excluded from fleet eligibility fingerprints

## Fleet Lanes

Fleet routing uses shared work lanes derived from model offerings. A lane describes the work required, not the worker that happens to do it.

```ruby
offering.lane_key
# => "llm.fleet.inference.qwen3-6-27b-q4-k-m.ctx32768"
```

Embedding lanes omit context size:

```ruby
LexLLM::Routing::ModelOffering.new(
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

## Schema Status

`lex-llm` still depends on `ruby_llm-schema` because the current schema bridge exposes:

```ruby
LexLLM::Schema
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
