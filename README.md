# lex-llm

Shared LegionIO LLM provider framework.

`lex-llm` owns the provider-neutral primitives that concrete LLM provider extensions share: model metadata, routing offering structures, provider capability normalization, and common request/response helpers. Concrete providers should live in dedicated gems such as `lex-llm-ollama`, `lex-llm-vllm`, `lex-llm-openai`, and `lex-llm-anthropic`.

## Namespace

The gem exposes two runtime namespaces:

- `LexLLM` for the shared Ruby API and provider primitives.
- `Legion::Extensions::Llm` for LegionIO extension loading and settings integration.

Provider gems must use nested Legion extension namespaces. For example, `lex-llm-ollama` should load from `legion/extensions/llm/ollama` and define `Legion::Extensions::Llm::Ollama`.

## Install

```ruby
gem 'lex-llm'
```

## Attribution

This gem began as a LegionIO fork of RubyLLM. RubyLLM remains credited under the MIT license; see `LICENSE`.
