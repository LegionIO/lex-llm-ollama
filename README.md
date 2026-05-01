# lex-llm-ollama

LegionIO LLM provider extension for [Ollama](https://ollama.ai).

This gem lives under `Legion::Extensions::Llm::Ollama` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

Load it with `require 'legion/extensions/llm/ollama'`.

## What It Provides

- `Legion::Extensions::Llm::Provider` registration as `:ollama`
- Ollama-native chat requests through `POST /api/chat`
- Streaming chat support
- Model discovery through `GET /api/tags`
- Running model inspection through `GET /api/ps`
- Model details through `POST /api/show`
- Model download helper through `POST /api/pull`
- Embeddings through `POST /api/embed`
- Best-effort `llm.registry` availability events from readiness and model discovery when Legion Transport is loaded
- Shared fleet/default settings via `Legion::Extensions::Llm.provider_settings`
- Full `Legion::Logging::Helper` integration with structured `handle_exception` in every rescue block

## Architecture

```
Legion::Extensions::Llm::Ollama
├── Provider               # Ollama provider (chat, stream, embed, models, readiness)
├── RegistryPublisher      # Best-effort async llm.registry event publishing
├── RegistryEventBuilder   # Sanitized lex-llm registry envelope construction
└── Transport/
    ├── Exchanges::LlmRegistry     # Topic exchange for llm.registry
    └── Messages::RegistryEvent    # AMQP message wrapper for registry events
```

## Defaults

```ruby
Legion::Extensions::Llm::Ollama.default_settings
# {
#   provider_family: :ollama,
#   instances: {
#     default: {
#       endpoint: "http://localhost:11434",
#       tier: :local,
#       transport: :http,
#       usage: { inference: true, embedding: true },
#       limits: { concurrency: 1 }
#     }
#   }
# }
```

## Configuration

```ruby
Legion::Extensions::Llm.configure do |config|
  config.ollama_api_base = "http://localhost:11434"
  config.default_model = "qwen3.6:27b"
  config.default_embedding_model = "nomic-embed-text:latest"
end
```

## Development

```bash
bundle install
bundle exec rspec       # 0 failures
bundle exec rubocop -A  # auto-fix
bundle exec rubocop     # lint check
```

## License

Apache-2.0
