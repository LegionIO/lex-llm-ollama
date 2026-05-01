# lex-llm-ollama

LegionIO LLM provider extension for [Ollama](https://ollama.ai).

This gem lives under `Legion::Extensions::Llm::Ollama` and depends on `lex-llm` (>= 0.1.9) for shared provider-neutral routing, fleet, transport, and registry primitives.

Load it with `require 'legion/extensions/llm/ollama'`.

## What It Provides

- Ollama-native chat requests through `POST /api/chat`
- Streaming chat support
- Model discovery through `GET /api/tags` with automatic embedding capability inference
- Running model inspection through `GET /api/ps`
- Model details through `POST /api/show`
- Model download helper through `POST /api/pull`
- Embeddings through `POST /api/embed`
- Best-effort `llm.registry` availability events via the shared `Legion::Extensions::Llm::RegistryPublisher`
- Full settings schema with model whitelist/blacklist, TLS, and multi-host base URL resolution
- Full `Legion::Logging::Helper` integration with structured `handle_exception` in every rescue block

## Architecture

```
Legion::Extensions::Llm::Ollama
├── Provider               # Ollama provider (chat, stream, embed, models, readiness)
└── (shared from lex-llm)
    ├── RegistryPublisher      # Best-effort async llm.registry event publishing
    ├── RegistryEventBuilder   # Sanitized registry envelope construction
    └── Transport/             # Shared exchange and message classes
```

## Defaults

```ruby
Legion::Extensions::Llm::Ollama.default_settings
# {
#   enabled: false,
#   base_url: '127.0.0.1:11434',
#   default_model: 'qwen3.5:latest',
#   model_whitelist: [],
#   model_blacklist: [],
#   model_cache_ttl: 60,
#   tls: { enabled: false, verify: :peer },
#   instances: {}
# }
```

## Configuration

```ruby
Legion::Extensions::Llm.configure do |config|
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
